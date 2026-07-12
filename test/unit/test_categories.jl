# Unit tests for the Categories module.
#
# Exercises the self-contained helpers that build SQL fragments for
# composition categorisation, independent of server state and FuncDB.

using Test
using MetaManifold.Categories

@testset "Categories helpers" begin
    @test Categories.column_name("default") == "Category__default"

    # Pattern keep on an available column compiles to a LIKE condition.
    cfg = Dict("filters" => [Dict("column" => "Domain", "pattern" => "Bacteria", "action" => "keep")])
    conds = Categories.filter_to_sql_conditions(cfg, Set(["Domain"]), "m")
    @test length(conds) == 1
    @test occursin("LIKE '%Bacteria%'", conds[1])

    # A column absent from the set is skipped, not errored.
    conds_missing = Categories.filter_to_sql_conditions(cfg, Set(["Genus"]), "m")
    @test isempty(conds_missing)

    # CASE WHEN falls through to Unassigned.
    cats = [Dict("name" => "Bacteria", "filter" => "bacteria.pr2.yml")]
    case = Categories.category_case_when(cats, Set(["Domain"]), "VSEARCH";
                                         filters_dir = joinpath(@__DIR__, "..", "..", "config", "filters"))
    @test occursin("ELSE 'Unassigned'", case)
    @test occursin("THEN 'Bacteria'", case)

    # Empty table_alias produces bare column references (for UPDATE SET contexts).
    case_bare = Categories.category_case_when(cats, Set(["Domain"]), "VSEARCH";
                                              filters_dir = joinpath(@__DIR__, "..", "..", "config", "filters"),
                                              table_alias = "")
    @test occursin("\"Domain\"", case_bare)
    @test !occursin("m.\"Domain\"", case_bare)
end

@testset "write_category_columns! on a merged table" begin
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    DBInterface.execute(con, """CREATE TABLE merged AS SELECT * FROM (VALUES
        ('asv1','Bacteria', 10),
        ('asv2','Eukaryota', 5)) AS t("SeqName","Domain","A_s1")""")
    Categories.write_category_columns!(con, "merged", "VSEARCH", ["default"];
        compositions_dir = joinpath(@__DIR__, "..", "..", "config", "compositions"),
        filters_dir      = joinpath(@__DIR__, "..", "..", "config", "filters"))
    rows = DataFrame(DBInterface.execute(con, """SELECT "Category__default" AS c FROM merged ORDER BY "SeqName" """))
    @test "Category__default" in names(DataFrame(DBInterface.execute(con,
        "SELECT * FROM merged LIMIT 0")))
    @test all(!ismissing, rows.c)
end

@testset "apply_max_x! deletes high-X rows" begin
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    # asv1 has 0 _X placeholders (keep when max_x=0), asv2 has 2 (delete when max_x=0).
    DBInterface.execute(con, """CREATE TABLE merged AS SELECT * FROM (VALUES
        ('asv1', 'Bacteria',   'Firmicutes'),
        ('asv2', 'Domain_X',   'Class_X')) AS t("SeqName","Domain","Class")""")
    Categories.apply_max_x!(con, "merged", ["Domain", "Class"], 0)
    rows = DataFrame(DBInterface.execute(con, "SELECT \"SeqName\" FROM merged"))
    @test nrow(rows) == 1
    @test rows.SeqName[1] == "asv1"
end

@testset "ensure_columns! is idempotent" begin
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    DBInterface.execute(con, """CREATE TABLE merged AS SELECT * FROM (VALUES
        ('asv1', 'Bacteria')) AS t("SeqName","Domain")""")
    comps_dir = joinpath(@__DIR__, "..", "..", "config", "compositions")
    flt_dir   = joinpath(@__DIR__, "..", "..", "config", "filters")
    # First call writes the column.
    Categories.ensure_columns!(con, "merged", "VSEARCH", ["default"];
                                compositions_dir=comps_dir, filters_dir=flt_dir)
    @test "Category__default" in names(DataFrame(DBInterface.execute(con,
        "SELECT * FROM merged LIMIT 0")))
    # Capture the category value written by the first call.
    val_before = DataFrame(DBInterface.execute(con,
        """SELECT "Category__default" AS c FROM merged WHERE "SeqName" = 'asv1'""")).c[1]
    # Second call must not error, must leave the column in place, and must not
    # alter any category value already written.
    Categories.ensure_columns!(con, "merged", "VSEARCH", ["default"];
                                compositions_dir=comps_dir, filters_dir=flt_dir)
    @test "Category__default" in names(DataFrame(DBInterface.execute(con,
        "SELECT * FROM merged LIMIT 0")))
    val_after = DataFrame(DBInterface.execute(con,
        """SELECT "Category__default" AS c FROM merged WHERE "SeqName" = 'asv1'""")).c[1]
    @test val_before == val_after
end

@testset "category exclusion drops the classified rows (mechanism)" begin
    flt_dir = joinpath(@__DIR__, "..", "..", "config", "filters")
    # Synthetic single-category set, independent of the shipped biology.
    cats = [Dict("name" => "Contaminant", "filter" => "vertebrates.pr2.yml")]

    db = DuckDB.DB()
    con = DBInterface.connect(db)
    # asv1 is a vertebrate (Craniata) host row; asv2 is not.
    DBInterface.execute(con, """CREATE TABLE merged AS SELECT * FROM (VALUES
        ('asv1', 'Craniata',   10),
        ('asv2', 'Clostridia',  5)) AS t("SeqName","Class","A_s1")""")

    # Bare-column CASE mirrors the fragment analysis appends to a WHERE clause.
    case = Categories.category_case_when(cats, Set(["SeqName","Class","A_s1"]),
                                         "VSEARCH"; filters_dir=flt_dir,
                                         table_alias="", strict=true)
    @test case !== nothing
    labelled = DataFrame(DBInterface.execute(con,
        "SELECT ($case) AS c FROM merged ORDER BY \"SeqName\""))
    @test labelled.c == ["Contaminant", "Unassigned"]

    # Excluding the Contaminant category drops exactly the matched row.
    kept = DataFrame(DBInterface.execute(con,
        "SELECT \"SeqName\" AS s FROM merged WHERE ($case) != 'Contaminant' ORDER BY \"SeqName\""))
    @test kept.s == ["asv2"]
end

@testset "shipped contamination set keeps only the whitelist" begin
    comps_dir = joinpath(@__DIR__, "..", "..", "config", "compositions")
    flt_dir   = joinpath(@__DIR__, "..", "..", "config", "filters")
    cfg = Categories.load_category_set("contamination"; compositions_dir=comps_dir)
    @test !isnothing(cfg)
    cats = get(cfg, "categories", [])
    names = [get(c, "name", "") for c in cats]
    @test "Retained" in names
    @test "Contaminant" in names

    # Realisable once the whitelist column (Genus) exists. Retained is a branch;
    # Contaminant is the filterless catch-all (the ELSE label).
    case = Categories.category_case_when(cats, Set(["SeqName", "Domain", "Genus"]),
                                         "VSEARCH"; filters_dir=flt_dir,
                                         table_alias="", strict=true)
    @test case !== nothing
    @test occursin("THEN 'Retained'", case)
    @test occursin("ELSE 'Contaminant'", case)

    db = DuckDB.DB()
    con = DBInterface.connect(db)
    # A whitelisted genus is Retained; a classified non-whitelist genus AND an
    # unclassified (no-Domain) row both fall into the Contaminant catch-all.
    DBInterface.execute(con, """CREATE TABLE merged AS SELECT * FROM (VALUES
        ('asv1', 'Eukaryota', 'Blastocystis'),
        ('asv2', 'Bacteria',  'Escherichia'),
        ('asv3', NULL,        NULL)) AS t("SeqName","Domain","Genus")""")
    labelled = DataFrame(DBInterface.execute(con,
        "SELECT ($case) AS c FROM merged ORDER BY \"SeqName\""))
    @test labelled.c == ["Retained", "Contaminant", "Contaminant"]
    # Excluding Contaminant keeps only the whitelisted row; the unclassified row
    # is dropped too, per the whitelist-only intent.
    kept = DataFrame(DBInterface.execute(con,
        "SELECT \"SeqName\" AS s FROM merged WHERE ($case) != 'Contaminant' ORDER BY \"SeqName\""))
    @test kept.s == ["asv1"]

    # Missing the whitelist column: not realisable, so nothing is dropped.
    @test Categories.category_case_when(cats, Set(["SeqName", "Domain"]), "VSEARCH";
                                        filters_dir=flt_dir, table_alias="", strict=true) === nothing

    # filter_column_refs surfaces the whitelist column, source-translated.
    wl = YAML.load_file(joinpath(flt_dir, "eukaryome_whitelist.yml"))
    @test "Genus" in Categories.filter_column_refs(wl)
    @test "Genus_dada2" in Categories.filter_column_refs(wl;
        col_map = Categories.col_translate_map("DADA2"))
end

@testset "filterless category names the catch-all bucket" begin
    flt_dir = joinpath(@__DIR__, "..", "..", "config", "filters")
    cats = [Dict("name" => "Keep", "filter" => "vertebrates.pr2.yml"),
            Dict("name" => "Rest")]  # no filter: catch-all
    case = Categories.category_case_when(cats, Set(["SeqName", "Class"]), "VSEARCH";
                                         filters_dir=flt_dir, table_alias="")
    @test occursin("THEN 'Keep'", case)
    @test occursin("ELSE 'Rest'", case)
    @test !occursin("Unassigned", case)

    # With no filtered branch at all, a filterless set is just the catch-all
    # literal (non-strict) and nothing under strict (no branch to trust).
    only_rest = [Dict("name" => "Rest")]
    @test Categories.category_case_when(only_rest, Set(["Class"]), "VSEARCH";
                                        filters_dir=flt_dir, table_alias="") == "'Rest'"
    @test Categories.category_case_when(only_rest, Set(["Class"]), "VSEARCH";
                                        filters_dir=flt_dir, table_alias="", strict=true) === nothing
end
