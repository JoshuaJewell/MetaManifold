# Unit tests for the CompositionLibrary module: loading config/composition.yml.

@testset "CompositionLibrary.load" begin
    dir = mktempdir()
    path = joinpath(dir, "composition.yml")
    write(path, """
    filters:
      bacteria:
        filters:
          - { column: Domain, type: include, values: [Bacteria] }
    sets:
      default:
        label: "Default Composition"
        categories:
          - { name: Bacteria, colour: "#8e44ad", filter: bacteria }
          - { name: Other, colour: "#c0392b" }
    """)

    lib = CompositionLibrary.load(path)
    @test haskey(lib["filters"], "bacteria")
    @test haskey(lib["sets"], "default")
    @test lib["sets"]["default"]["categories"][1]["name"] == "Bacteria"
    # A filter-less category is retained; it is the catch-all.
    @test !haskey(lib["sets"]["default"]["categories"][2], "filter")

    # A missing file yields an empty library rather than an error.
    empty_lib = CompositionLibrary.load(joinpath(dir, "absent.yml"))
    @test isempty(empty_lib["filters"])
    @test isempty(empty_lib["sets"])
end

@testset "category_case_when resolves filters by name" begin
    filters = Dict{String,Any}(
        "bacteria" => Dict("filters" => [Dict("column" => "Domain",
                                              "type" => "include",
                                              "values" => ["Bacteria"])]),
    )
    cats = [Dict("name" => "Bacteria", "filter" => "bacteria"),
            Dict("name" => "Contaminant")]

    case = Categories.category_case_when(cats, Set(["Domain"]), "VSEARCH"; filters)
    # The named filter compiles to a branch.
    @test occursin("THEN 'Bacteria'", case)
    # A filter-less category becomes the catch-all ELSE label.
    @test occursin("ELSE 'Contaminant'", case)

    # A dangling name is dropped for display, and fails hard under strict.
    dangling = [Dict("name" => "Ghost", "filter" => "absent")]
    @test Categories.category_case_when(dangling, Set(["Domain"]), "VSEARCH";
                                        filters, strict=true) === nothing

    # (a) Branch precedence: two filtered categories compile in declaration
    # order, so the first-declared category's WHEN precedes the second's
    # (CASE WHEN takes the first match, so order is load-bearing).
    ordered_filters = Dict{String,Any}(
        "bacteria" => Dict("filters" => [Dict("column" => "Domain",
                                              "type" => "include",
                                              "values" => ["Bacteria"])]),
        "archaea" => Dict("filters" => [Dict("column" => "Domain",
                                             "type" => "include",
                                             "values" => ["Archaea"])]),
    )
    ordered_cats = [Dict("name" => "Bacteria", "filter" => "bacteria"),
                    Dict("name" => "Archaea", "filter" => "archaea")]
    ordered_case = Categories.category_case_when(ordered_cats, Set(["Domain"]),
                                                 "VSEARCH"; filters=ordered_filters)
    bacteria_idx = findfirst("THEN 'Bacteria'", ordered_case)
    archaea_idx = findfirst("THEN 'Archaea'", ordered_case)
    @test bacteria_idx !== nothing && archaea_idx !== nothing
    @test first(bacteria_idx) < first(archaea_idx)

    # (b) With two filterless categories, the LAST one is the catch-all: its
    # name becomes the label, not the first's. Neither contributes a WHEN
    # branch, so with no other categories the result is the bare catch-all
    # literal rather than a full CASE expression.
    two_catchalls = [Dict("name" => "First"), Dict("name" => "Second")]
    catchall_case = Categories.category_case_when(two_catchalls, Set(["Domain"]),
                                                   "VSEARCH"; filters=Dict{String,Any}())
    @test catchall_case == "'Second'"
    @test !occursin("First", catchall_case)

    # (c) A filter resolved by name but referencing a column absent from
    # merged_col_set fails the strict per-column check (distinct from a
    # dangling filter name), yet still yields a usable string for display.
    absent_col_filters = Dict{String,Any}(
        "species_only" => Dict("filters" => [Dict("column" => "Species",
                                                   "type" => "include",
                                                   "values" => ["Foo"])]),
    )
    absent_col_cats = [Dict("name" => "SpeciesCat", "filter" => "species_only")]
    @test Categories.category_case_when(absent_col_cats, Set(["Domain"]), "VSEARCH";
                                        filters=absent_col_filters, strict=true) === nothing
    absent_col_display = Categories.category_case_when(absent_col_cats, Set(["Domain"]),
                                                        "VSEARCH"; filters=absent_col_filters,
                                                        strict=false)
    @test absent_col_display isa String
    @test absent_col_display == "'Unassigned'"

    # (d) Under display, a dangling category is dropped but the classification
    # degrades rather than collapsing: other valid categories still produce
    # their branches.
    mixed_filters = Dict{String,Any}(
        "bacteria" => Dict("filters" => [Dict("column" => "Domain",
                                              "type" => "include",
                                              "values" => ["Bacteria"])]),
    )
    mixed_cats = [Dict("name" => "Ghost", "filter" => "absent_filter"),
                  Dict("name" => "Bacteria", "filter" => "bacteria")]
    mixed_case = Categories.category_case_when(mixed_cats, Set(["Domain"]), "VSEARCH";
                                               filters=mixed_filters, strict=false)
    @test !occursin("Ghost", mixed_case)
    @test occursin("THEN 'Bacteria'", mixed_case)
end

@testset "CompositionLibrary.validate" begin
    good = Dict{String,Any}(
        "filters" => Dict("bacteria" => Dict("filters" => [])),
        "sets" => Dict("default" => Dict("categories" =>
            [Dict("name" => "Bacteria", "colour" => "#8e44ad", "filter" => "bacteria")])),
    )
    @test isempty(CompositionLibrary.validate(good))

    # A set naming an absent filter is rejected.
    dangling = deepcopy(good)
    dangling["sets"]["default"]["categories"][1]["filter"] = "absent"
    errs = CompositionLibrary.validate(dangling)
    @test length(errs) == 1
    @test occursin("absent", errs[1])

    # A malformed colour is rejected.
    bad_colour = deepcopy(good)
    bad_colour["sets"]["default"]["categories"][1]["colour"] = "blue"
    @test !isempty(CompositionLibrary.validate(bad_colour))

    # filter_in_use reports the referencing sets.
    @test CompositionLibrary.filter_in_use(good, "bacteria") == ["default"]
    @test isempty(CompositionLibrary.filter_in_use(good, "unused"))

    # A filter with a non-Dict value is rejected.
    non_dict_value = Dict{String,Any}(
        "filters" => Dict{String,Any}("bacteria" => "not a dict"),
        "sets" => Dict("default" => Dict("categories" =>
            [Dict("name" => "Bacteria", "colour" => "#8e44ad", "filter" => "bacteria")])),
    )
    errs = CompositionLibrary.validate(non_dict_value)
    @test !isempty(errs)
    @test any(occursin("bacteria", e) && occursin("Dict", e) for e in errs)

    # The catch-all (filter-less) category is never flagged as an error.
    catchall = Dict{String,Any}(
        "filters" => Dict{String,Any}(),
        "sets" => Dict("default" => Dict("categories" => [Dict("name" => "Other")])),
    )
    @test isempty(CompositionLibrary.validate(catchall))
end

@testset "CompositionLibrary.validate never throws on malformed input" begin
    # A set config that is not a Dict.
    not_a_dict_set = Dict{String,Any}("sets" => Dict("default" => "oops_not_a_dict"))
    errs = CompositionLibrary.validate(not_a_dict_set)
    @test !isempty(errs)

    # A set whose categories is a Vector of non-Dict entries.
    not_a_dict_categories = Dict{String,Any}(
        "sets" => Dict("default" => Dict("categories" => ["not", "a", "dict"])),
    )
    errs = CompositionLibrary.validate(not_a_dict_categories)
    @test !isempty(errs)

    # A set whose categories is a bare String, which must not be iterated
    # character by character.
    string_categories = Dict{String,Any}(
        "sets" => Dict("default" => Dict("categories" => "whoops")),
    )
    errs = CompositionLibrary.validate(string_categories)
    @test !isempty(errs)

    # A filters section that is not a Dict.
    not_a_dict_filters = Dict{String,Any}("filters" => "oops")
    errs = CompositionLibrary.validate(not_a_dict_filters)
    @test !isempty(errs)
end

@testset "CompositionLibrary numeric filter names round-trip through YAML" begin
    dir = mktempdir()
    path = joinpath(dir, "composition.yml")
    write(path, """
    filters:
      123:
        filters:
          - { column: Domain, type: include, values: [Bacteria] }
    sets:
      default:
        label: "Default Composition"
        categories:
          - { name: NumFilter, colour: "#123456", filter: 123 }
          - { name: Other, colour: "#654321" }
    """)

    lib = CompositionLibrary.load(path)
    # The unquoted numeric key and the numeric reference both round-trip as
    # Strings, so the reference is not reported as dangling.
    errs = CompositionLibrary.validate(lib)
    @test isempty(errs)
    @test CompositionLibrary.filter_in_use(lib, "123") == ["default"]

    # The catch-all (filter-less) category is still not flagged as an error.
    @test !any(occursin("Other", e) for e in errs)
end
