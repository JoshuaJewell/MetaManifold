# Unit tests for the HTTP server's route helper functions.
#
# server.jl includes the route files into `module Server`, defining their
# helper functions in that scope. Including it here (rather than spawning a
# subprocess as the smoke tests do) lets these helpers run inside the
# coverage-instrumented process, so their lines are counted. Including the
# module does not start the HTTP listener; only Server.start() does that.
if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end
SV = Main.Server

@testset "Route helpers" begin

    ## studies.jl: pure name validation
    @testset "_valid_name" begin
        @test SV._valid_name("studyA")
        @test SV._valid_name("run_1")
        @test SV._valid_name("a.b-c_2")
        @test !SV._valid_name("")
        @test !SV._valid_name(".hidden")
        @test !SV._valid_name(".")
        @test !SV._valid_name("..")
        @test !SV._valid_name("a/b")
        @test !SV._valid_name("a b")
        @test !SV._valid_name("naughty;rm")
    end

    ## studies.jl: filesystem enumerators over a synthetic data tree
    @testset "study and run enumeration" begin
        tmp = mktempdir()
        data = joinpath(tmp, "data")
        ## A plain run with a paired-end sample
        mkpath(joinpath(data, "studyA", "run1"))
        touch(joinpath(data, "studyA", "run1", "sampleX_R1.fastq.gz"))
        touch(joinpath(data, "studyA", "run1", "sampleX_R2.fastq.gz"))
        ## A second plain run, single sample
        mkpath(joinpath(data, "studyA", "run2"))
        touch(joinpath(data, "studyA", "run2", "s2_R1.fastq.gz"))
        ## A group directory (no direct fastq, contains a run)
        mkpath(joinpath(data, "studyA", "groupG", "runG1"))
        touch(joinpath(data, "studyA", "groupG", "runG1", "g_R1.fastq.gz"))
        ## A pooled run (marked by pool_children, with a prefixed child)
        mkpath(joinpath(data, "studyA", "pooledRun", "childA"))
        write(joinpath(data, "studyA", "pooledRun", "pipeline.yml"), "pool_children: true\n")
        touch(joinpath(data, "studyA", "pooledRun", "childA", "c_R1.fastq.gz"))

        SV.ServerState.set_root!(tmp)

        @test SV._study_names() == ["studyA"]
        @test SV._is_pooled(joinpath(data, "studyA", "pooledRun"))
        @test !SV._is_pooled(joinpath(data, "studyA", "run1"))

        @test Set(SV._run_names("studyA")) == Set(["run1", "run2", "pooledRun"])
        @test SV._group_names("studyA") == ["groupG"]
        @test SV._group_run_names("studyA", "groupG") == ["runG1"]

        @test SV._run_group("studyA", "runG1") == "groupG"
        @test SV._run_group("studyA", "run1") === nothing

        @test SV._sample_names("studyA", "run1") == ["sampleX"]
        @test SV._sample_names("studyA", "run2") == ["s2"]
        ## Pooled samples are prefixed by their child directory name.
        @test SV._sample_names("studyA", "pooledRun") == ["childA_c"]
        ## Unknown study or run yields an empty list, never an error.
        @test SV._run_names("nope") == String[]
        @test SV._sample_names("studyA", "nope") == String[]

        rm(tmp; recursive=true)
    end

    ## config.jl: flattening and key validation
    @testset "config flattening" begin
        nested = Dict("a" => Dict("b" => 1, "c" => 2), "d" => 3)
        flat = SV._flatten(nested)
        @test flat["a.b"] == 1
        @test flat["a.c"] == 2
        @test flat["d"] == 3
        @test SV._flatten(Dict{String,Any}()) == Dict{String,Any}()
    end

    @testset "config key validation" begin
        @test_throws ErrorException SV._validate_config_key("definitely.not.a.key")
        ## Any key present in the factory defaults must validate.
        if !isempty(SV._ALLOWED_CONFIG_KEYS)
            @test SV._validate_config_key(first(SV._ALLOWED_CONFIG_KEYS))
        end
    end

    ## duckdb_helpers.jl: SQL fragment builders (parameterised, injection-safe)
    @testset "_build_where" begin
        cols = ["Genus", "Pident"]
        @test SV._build_where(Dict{String,String}(), cols) == ("", Any[])

        where, params = SV._build_where(Dict("col.Genus" => "escherichia"), cols)
        @test occursin("LOWER(CAST(\"Genus\" AS VARCHAR)) LIKE ?", where)
        @test params == ["%escherichia%"]

        ## A filter on an unknown column is ignored.
        @test SV._build_where(Dict("col.Bogus" => "x"), cols) == ("", Any[])

        wi, pi = SV._build_where(Dict("col_in.Genus" => "A|B"), cols)
        @test occursin("CAST(\"Genus\" AS VARCHAR) IN (?, ?)", wi)
        @test pi == ["A", "B"]

        wm, pm = SV._build_where(Dict("col_min.Pident" => "97"), cols)
        @test occursin(">= ?", wm)
        @test pm == [97.0]
    end

    @testset "_order_clause" begin
        cols = ["Genus", "SeqName"]
        @test SV._order_clause(nothing, "asc", cols) == ""
        @test SV._order_clause("Genus", "asc", cols) == "ORDER BY \"Genus\" ASC"
        @test SV._order_clause("Genus", "desc", cols) == "ORDER BY \"Genus\" DESC"
        ## A sort column absent from the table is dropped.
        @test SV._order_clause("Missing", "asc", cols) == ""
        ## SeqName receives natural-order sorting via regexp_extract.
        @test occursin("regexp_extract", SV._order_clause("SeqName", "asc", cols))
    end

    ## runs.jl: config-flag traversal
    @testset "_config_flag" begin
        @test SV._config_flag(nothing, ["dada2"], true)
        @test !SV._config_flag(nothing, ["dada2"], false)
        on  = Dict("dada2" => Dict("taxonomy" => Dict("enabled" => true)))
        off = Dict("dada2" => Dict("taxonomy" => Dict("enabled" => false)))
        bare = Dict("dada2" => Dict("taxonomy" => Dict{String,Any}()))
        @test SV._config_flag(on,  ["dada2", "taxonomy"], false)
        @test !SV._config_flag(off, ["dada2", "taxonomy"], true)
        ## A missing "enabled" key falls back to the supplied default.
        @test SV._config_flag(bare, ["dada2", "taxonomy"], true)
        ## A path that is not a section returns the default.
        @test SV._config_flag(Dict("other" => 1), ["dada2"], true)

        @test SV._classify_enabled(off) == false
        @test SV._classify_enabled(nothing) == true
    end

    ## pipeline.jl: the database key a run's config names
    @testset "_run_database" begin
        # The route must honour the run's config, as DADA2's _resolve_taxonomy_db
        # and Validation.validate_project both already do. _load_dbs read a `default:`
        # section that no databases.yml defines, so it always answered "pr2" and
        # silently ignored the study's choice: adding a database would have been a
        # feature that did nothing.
        @test SV._run_database(Dict("dada2" => Dict("taxonomy" =>
            Dict("database" => "eukaryome")))) == "eukaryome"
        # Absent, the factory default applies. This mirrors the fallback in
        # validate.jl and provenance.jl rather than inventing a third rule.
        @test SV._run_database(Dict("dada2" => Dict("taxonomy" => Dict()))) == "pr2"
        @test SV._run_database(Dict()) == "pr2"
        # Rubbish in the config must not throw out of a route.
        @test SV._run_database(Dict("dada2" => "scalar")) == "pr2"
        @test SV._run_database(Dict("dada2" => Dict("taxonomy" => "scalar"))) == "pr2"
    end

    ## annotations.jl: source validation and taxon-column mapping
    @testset "annotation helpers" begin
        @test SV._validate_source("VSEARCH")
        @test SV._validate_source("DADA2")
        @test !SV._validate_source("BLAST")
        @test !SV._validate_source("")

        ## Every rank in the hierarchy maps to its source-specific column.
        for entry in MetaManifold.FuncDBAnnotation.RANK_HIERARCHY
            @test SV._matched_taxon_column("VSEARCH", entry.rank) == entry.vsearch
            @test SV._matched_taxon_column("DADA2", entry.rank) == entry.dada2
            @test SV._annotation_required_col("VSEARCH", entry.rank) == entry.vsearch
        end
        @test SV._matched_taxon_column("VSEARCH", "no_such_rank") === nothing

        ## The BLAST assignment column is synthesised when absent.
        @test SV._annotation_select_expr(["Genus"]) ==
              "*, '' AS \"BLAST Assignment\""
        @test SV._annotation_select_expr(["Genus", "BLAST Assignment"]) == "*"
        @test SV._annotation_response_columns(["Genus"]) ==
              ["Genus", "BLAST Assignment"]
        @test SV._annotation_response_columns(["Genus", "BLAST Assignment"]) ==
              ["Genus", "BLAST Assignment"]
    end

    ## config.jl: per-study chart cosmetics resolution
    @testset "chart cosmetics" begin
        tmp = mktempdir()
        study_dir = joinpath(tmp, "data", "StudyX"); mkpath(study_dir)
        old_root = SV.ServerState._root[]
        SV.ServerState.set_root!(tmp)
        try
            @test isempty(SV._resolve_chart_cosmetics("StudyX", "taxa_bar"))

            write(joinpath(study_dir, "pipeline.yml"), """
            chart_cosmetics:
              taxa_bar:
                layout:
                  title:
                    text: My bars
                traces:
                  Bacteria:
                    marker:
                      color: "#00ff00"
            """)
            cos = SV._resolve_chart_cosmetics("StudyX", "taxa_bar")
            @test cos["layout"]["title"]["text"] == "My bars"
            @test cos["traces"]["Bacteria"]["marker"]["color"] == "#00ff00"
            @test isempty(SV._resolve_chart_cosmetics("StudyX", "alpha_richness"))
        finally
            SV.ServerState.set_root!(old_root)
            rm(tmp; recursive=true, force=true)
        end
    end

    ## analysis.jl: aggregate run expansion
    @testset "aggregate run expansion" begin
        # Two specs for the same run with different sub-group prefixes.
        # Symbol keys mirror what JSON3 produces from a parsed request body.
        specs = [(; run="RunA", group=nothing, prefix="Caecum", source=nothing),
                 (; run="RunA", group=nothing, prefix="Ileum",  source=nothing)]
        agg = SV._expand_comparison_run_specs("StudyX", specs; aggregate=true)
        @test length(agg) == 2          # one per input spec, but all prefix=nothing
        @test all(s -> isnothing(s.prefix), agg)
        @test all(s -> s.run == "RunA", agg)
    end

    ## analysis.jl: pure label, prefix and matrix helpers
    @testset "analysis helpers" begin
        @test SV._opt_string((; a = "x"), :a) == "x"
        @test SV._opt_string((; a = ""), :a) === nothing
        @test SV._opt_string((;), :a) === nothing

        @test SV._filter_by_prefix(["A_s1", "A_s2", "B_s1"], "A") == ["A_s1", "A_s2"]
        @test SV._filter_by_prefix(["A_s1", "B_s1"], nothing) == ["A_s1", "B_s1"]

        @test SV._resolved_group_label((; prefix = "P", group = "G", run = "R")) == "P"
        @test SV._resolved_group_label((; prefix = nothing, group = "G", run = "R")) == "G"
        @test SV._resolved_group_label((; prefix = nothing, group = nothing, run = "R")) == "R"
        @test SV._resolved_run_label((; group = "G", run = "R")) == "G/R"
        @test SV._resolved_run_label((; group = nothing, run = "R")) == "R"

        ## Empty samples (zero total across features) are dropped, aligned
        ## vectors filtered in lockstep.
        mat = [1.0 0.0; 0.0 0.0; 2.0 3.0]
        (kept, names_kept), kept_n, total_n =
            SV._drop_empty_samples(mat, ["a", "b", "c"])
        @test kept == [1.0 0.0; 2.0 3.0]
        @test names_kept == ["a", "c"]
        @test kept_n == 2
        @test total_n == 3

        ## Venn labels include only the dimensions that vary across conditions.
        single = [(; group = nothing, run = "R", prefix = nothing)]
        @test SV._venn_condition_labels(single) == ["R"]
        by_run = [(; group = nothing, run = "R1", prefix = nothing),
                  (; group = nothing, run = "R2", prefix = nothing)]
        @test SV._venn_condition_labels(by_run) == ["R1", "R2"]
        by_group = [(; group = "G1", run = "R", prefix = nothing),
                    (; group = "G2", run = "R", prefix = nothing)]
        @test SV._venn_condition_labels(by_group) == ["G1", "G2"]
    end

    ## analysis.jl: unified chart core helper
    @testset "unified chart helper (_chart_data)" begin
        # Build an in-memory merged table with two taxonomy ranks and two sub-group prefixes.
        db  = DuckDB.DB()
        con = DBInterface.connect(db)
        DBInterface.execute(con, """
            CREATE TABLE merged (
                SeqName VARCHAR,
                Domain  VARCHAR,
                Genus   VARCHAR,
                A_s1 BIGINT, A_s2 BIGINT,
                B_s1 BIGINT, B_s2 BIGINT
            )
        """)
        DBInterface.execute(con, """
            INSERT INTO merged VALUES
                ('seq1', 'Eukaryota', 'Chlorella',    10, 0,  5, 2),
                ('seq2', 'Bacteria',  'Escherichia',   0, 20, 3, 0),
                ('seq3', 'Bacteria',  'Clostridium',   5, 5,  0, 0)
        """)

        all_scols = SV.Analysis.sample_columns(con, "merged")
        @test Set(all_scols) == Set(["A_s1", "A_s2", "B_s1", "B_s2"])
        columns = SV._duckdb_columns(con, "merged")

        ## tag=rank, no subgroup: all sample columns, rank=Genus
        res = SV._chart_data(con, "merged", columns, all_scols,
                             "", Any[], "rank", "Genus",
                             nothing, String[], "run1", 15, "VSEARCH")
        @test res isa NamedTuple
        @test Set(res.segment_labels) == Set(["Chlorella", "Escherichia", "Clostridium"])
        @test Set(res.sample_names) == Set(all_scols)
        @test size(res.counts) == (3, 4)

        ## tag=rank, subgroup prefix "A": only A_s1 and A_s2
        res_A = SV._chart_data(con, "merged", columns, all_scols,
                               "", Any[], "rank", "Genus",
                               "A", String[], "run1", 15, "VSEARCH")
        @test res_A isa NamedTuple
        @test Set(res_A.sample_names) == Set(["A_s1", "A_s2"])

        ## Zero-read guard: seq3 (Clostridium) has B_s1=0, B_s2=0 -> sum=0 -> dropped.
        # seq2 (Escherichia): B_s1=3, B_s2=0 -> non-zero, kept.
        res_B = SV._chart_data(con, "merged", columns, all_scols,
                               "", Any[], "rank", "Genus",
                               "B", String[], "run1", 15, "VSEARCH")
        @test res_B isa NamedTuple
        @test "Clostridium" ∉ res_B.segment_labels
        @test "Chlorella"   in res_B.segment_labels
        @test "Escherichia" in res_B.segment_labels

        ## subgroup=="__pool__": all samples used but pooled into group totals A and B
        res_pool = SV._chart_data(con, "merged", columns, all_scols,
                                  "", Any[], "rank", "Domain",
                                  "__pool__", ["A", "B"], "run1", 15, "VSEARCH")
        @test res_pool isa NamedTuple
        @test Set(res_pool.sample_names) == Set(["A", "B"])

        ## effective_top_n: typemax(Int) for categories, top_n for ranks
        res_cat_tn = SV._chart_data(con, "merged", columns, all_scols,
                                    "", Any[], "category", "noop_set",
                                    nothing, String[], "run1", 5, "VSEARCH")
        # Category set "noop_set" does not exist; the column is absent so DuckDB
        # will error. Accept either a success NamedTuple with typemax(Int) top_n
        # or an HTTP response (error path) - either way the route handles it.
        if res_cat_tn isa NamedTuple
            @test res_cat_tn.effective_top_n == typemax(Int)
        end

        ## Category happy path: write "default" category column, then call _chart_data.
        # Loads the shipped composition library so the "default" set is resolved
        # exactly as it is in production. Not config/composition.yml: that is the
        # machine copy, gitignored and editable from the UI, so a suite reading it
        # fails on a clean checkout and breaks whenever the user edits a set.
        lib_path = joinpath(@__DIR__, "..", "..", "config", "defaults", "composition.yml")
        library = SV.CompositionLibrary.load(lib_path)
        SV.Categories.write_category_columns!(con, "merged", "VSEARCH", ["default"]; library)
        columns_after = SV._duckdb_columns(con, "merged")
        # _chart_data with tag=category, value="default"; ensure_columns! is now a no-op.
        res_cat = SV._chart_data(con, "merged", columns_after, all_scols,
                                 "", Any[], "category", "default",
                                 nothing, String[], "run1", 5, "VSEARCH")
        @test res_cat isa NamedTuple
        @test res_cat.effective_top_n == typemax(Int)
        # Real category aggregation was exercised: at least one label returned.
        @test !isempty(res_cat.segment_labels)
        # All returned labels must be valid category names from the "default" set
        # (or "Unassigned"). The test table has only Domain and Genus columns so
        # only those filter branches that refer to available columns are applied.
        valid_labels = Set(["Protozoa", "Helminths", "Fungi", "Host", "Plants",
                            "Invertebrates", "Bacteria", "Archaea", "Unassigned"])
        @test all(lbl -> lbl in valid_labels, res_cat.segment_labels)

        DBInterface.close!(con)
        close(db)
    end

    @testset "exclude_categories apply_to surface parsing" begin
        # A missing apply_to means "all surfaces" (nothing).
        @test SV._parse_apply_to(nothing; set="s", category="c") === nothing
        # A malformed (non-list) value also degrades to all surfaces.
        @test SV._parse_apply_to("diversity"; set="s", category="c") === nothing
        # An explicit list is normalised to a set of known surfaces; case and
        # surrounding whitespace are tolerated.
        parsed = SV._parse_apply_to(["Diversity", " taxa ", "venn"]; set="s", category="c")
        @test parsed == Set(["diversity", "taxa", "venn"])
        @test !("composition" in parsed)
        # Unknown surfaces are dropped, not retained.
        @test SV._parse_apply_to(["taxa", "bogus"]; set="s", category="c") == Set(["taxa"])
        # An empty list applies to no surface (the exclusion becomes inert).
        @test SV._parse_apply_to(String[]; set="s", category="c") == Set{String}()
        # The known-surface vocabulary is exactly these four.
        @test SV._EXCLUSION_SURFACES == Set(["diversity", "taxa", "composition", "venn"])
    end

    ## CRITICAL 1 regression guard: an exclusion spec against a library-defined
    ## set must actually produce a dropping condition. Before the fix, the
    ## set's categories were read from the (mismatched) directory while its
    ## filters came from the library, so `category_case_when(...; strict=true)`
    ## always returned `nothing` and every exclusion was silently skipped.
    @testset "_exclusion_conditions resolves a library-defined set (CRITICAL 1 guard)" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            study, run = "studyX", "runX"
            mkpath(joinpath(tmp, "data", study, run))
            write(joinpath(tmp, "data", study, run, "pipeline.yml"), """
            analysis:
              exclude_categories:
                - set: host
                  category: Host
            """)
            mkpath(joinpath(tmp, "config"))
            write(joinpath(tmp, "config", "composition.yml"), """
            filters:
              host_filter:
                filters:
                  - { column: Class, pattern: Craniata, action: keep }
            sets:
              host:
                label: Host test
                categories:
                  - { name: Host, filter: host_filter }
                  - { name: NotHost }
            """)

            columns = ["SeqName", "Class", "A_s1"]
            conds = SV._exclusion_conditions(study, run, nothing, columns; surface="diversity")
            @test !isempty(conds)
            @test occursin("'Host'", conds[1])
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## composition.jl: filter-level and whole-library routes (Task 6)
    @testset "composition library routes" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            mkpath(joinpath(tmp, "config"))
            write(joinpath(tmp, "config", "composition.yml"), """
            filters:
              bacteria:
                filters:
                  - { column: Domain, pattern: Bacteria, action: keep }
            sets:
              default:
                label: Default
                categories:
                  - { name: Bacteria, colour: "#8e44ad", filter: bacteria }
            """)

            ## GET returns both sections.
            lib = SV._library()
            @test haskey(lib, "filters")
            @test haskey(lib, "sets")
            @test haskey(lib["filters"], "bacteria")
            @test haskey(lib["sets"], "default")

            ## POST a filter, then GET: it is there.
            saved = SV._save_filter("fungi",
                Dict("filters" => [Dict("column" => "Domain", "pattern" => "Fungi", "action" => "keep")]))
            @test saved isa AbstractDict
            @test haskey(SV._library()["filters"], "fungi")

            ## POST a set naming a non-existent filter is rejected (the dangling guard).
            bad = SV._save_composition_set("ghosted", Dict(
                "label"      => "Ghosted",
                "categories" => [Dict("name" => "Ghost", "filter" => "no_such_filter")],
            ))
            @test bad isa SV.HTTP.Response
            @test bad.status == 400
            @test JSON3.read(String(bad.body))["error"] == "invalid_library"
            @test !haskey(SV._library()["sets"], "ghosted")

            ## DELETE a filter that a set still references: 409, naming the set.
            in_use = SV._delete_filter("bacteria")
            @test in_use isa SV.HTTP.Response
            @test in_use.status == 409
            body_in_use = JSON3.read(String(in_use.body))
            @test body_in_use["error"] == "filter_in_use"
            @test occursin("default", body_in_use["message"])
            @test haskey(SV._library()["filters"], "bacteria")

            ## DELETE the `default` set is protected.
            protected = SV._delete_category_set("default")
            @test protected isa SV.HTTP.Response
            @test protected.status == 400
            @test JSON3.read(String(protected.body))["error"] == "protected_set"
            @test haskey(SV._library()["sets"], "default")

            ## POST a filter, then DELETE it (unreferenced): succeeds, gone from GET.
            SV._save_filter("unused", Dict("filters" => Any[]))
            @test haskey(SV._library()["filters"], "unused")
            deleted = SV._delete_filter("unused")
            @test deleted == "unused"
            @test !haskey(SV._library()["filters"], "unused")
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## config.jl: primers document routes (Task 3)
    @testset "primers document routes" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            cfgdir = joinpath(tmp, "config")
            mkpath(cfgdir)
            write(joinpath(cfgdir, "primers.yml"), """
            Forward:
              F1: "ACGT"
            Reverse:
              R1: "TGCA"
            Pairs:
              - P1:
                - F1
                - R1
            """)

            # GET returns the canonical shape. Reference the module through the
            # `MetaManifold.` prefix, which is always resolvable under the harness's
            # `using MetaManifold`; the submodule need not be exported.
            doc = MetaManifold.PrimersLibrary.load(SV._primers_path())
            @test doc["Pairs"][1]["name"] == "P1"

            # A clean PUT persists and round-trips. `_save_primers` returns the saved
            # canonical document (an AbstractDict) on success, or an HTTP.Response on
            # rejection, so the success discriminator is `isa AbstractDict`.
            good = Dict("Forward" => Dict("F1" => "ACGT", "F2" => "GGCC"),
                        "Reverse" => Dict("R1" => "TGCA"),
                        "Pairs"   => [Dict("name" => "P1", "forward" => "F2", "reverse" => "R1")])
            res = SV._save_primers(good)
            @test res isa AbstractDict
            reloaded = MetaManifold.PrimersLibrary.load(SV._primers_path())
            @test haskey(reloaded["Forward"], "F2")
            @test reloaded["Pairs"][1]["forward"] == "F2"

            # A dangling pair is rejected and the file is left unchanged.
            before = read(SV._primers_path(), String)
            bad = Dict("Forward" => Dict("F1" => "ACGT"),
                       "Reverse" => Dict("R1" => "TGCA"),
                       "Pairs"   => [Dict("name" => "P1", "forward" => "GHOST", "reverse" => "R1")])
            rej = SV._save_primers(bad)
            @test !(rej isa AbstractDict)
            @test rej.status == 400
            @test read(SV._primers_path(), String) == before

            # A body that is not a JSON object is rejected with an actionable 400
            # rather than throwing out of the route as a bare 500. This route backs
            # a Save button, where a malformed request is a plausible client bug.
            for body in ("", "[1,2,3]", "\"just a string\"", "null", "{oops")
                r = SV._primers_body(body)
                @test !(r isa AbstractDict)
                @test r.status == 400
            end

            # A well-formed body parses to the canonical shape validate expects,
            # with genuine String leaves rather than JSON3 views.
            ok = SV._primers_body("""
                {"Forward":{"F1":"ACGT"},"Reverse":{"R1":"TGCA"},
                 "Pairs":[{"name":"P1","forward":"F1","reverse":"R1"}]}
            """)
            @test ok isa AbstractDict
            @test isempty(MetaManifold.PrimersLibrary.validate(ok))
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## config.jl: cross-file pair-reference warning (Task 4)
    @testset "primers cross-file warning" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            cfgdir = joinpath(tmp, "config")
            mkpath(cfgdir)
            write(joinpath(cfgdir, "primers.yml"), """
            Forward:
              F1: "ACGT"
            Reverse:
              R1: "TGCA"
            Pairs:
              - P1:
                - F1
                - R1
              - P2:
                - F1
                - R1
            """)
            # A study pipeline.yml names pair P1 under cutadapt.primer_pairs.
            studydir = joinpath(tmp, "data", "StudyA")
            mkpath(studydir)
            write(joinpath(studydir, "pipeline.yml"), """
            cutadapt:
              primer_pairs:
                - P1
            """)

            # `current` is the document as it stands on disk, which the route
            # hands in from its own guarded read rather than re-reading here.
            current = MetaManifold.PrimersLibrary.load(SV._primers_path())

            # Dropping P1 (still referenced) warns and names the study; write succeeds.
            doc = Dict("Forward" => Dict("F1" => "ACGT"),
                       "Reverse" => Dict("R1" => "TGCA"),
                       "Pairs"   => [Dict("name" => "P2", "forward" => "F1", "reverse" => "R1")])
            warnings = SV._pair_pipeline_refs_removed(doc, current)
            @test length(warnings) == 1
            @test warnings[1]["pair"] == "P1"
            @test "StudyA" in warnings[1]["referenced_by"]

            # Dropping P2 (unreferenced) yields no warning.
            doc2 = Dict("Forward" => Dict("F1" => "ACGT"),
                        "Reverse" => Dict("R1" => "TGCA"),
                        "Pairs"   => [Dict("name" => "P1", "forward" => "F1", "reverse" => "R1")])
            @test isempty(SV._pair_pipeline_refs_removed(doc2, current))

            # A value set only in the GLOBAL config is inherited by every project
            # that does not override it, so it is reported against those projects.
            # "global" is not a project and is never a label: the warning answers
            # "which projects does this affect", and the global file is not one.
            write(joinpath(cfgdir, "pipeline.yml"), "cutadapt:\n  primer_pairs:\n    - P2\n")
            rm(joinpath(studydir, "pipeline.yml"); force=true)
            write(joinpath(studydir, "pipeline.yml"), "cutadapt:\n  cores: 2\n")
            @test SV._cascade_refs("cutadapt.primer_pairs")["P2"] == ["StudyA"]
            @test !("global" in SV._cascade_refs("cutadapt.primer_pairs")["P2"])

            # A value set only in config/defaults/pipeline.yml is FACTORY config.
            # The file is not a referencing location and never appears as a label,
            # but its value IS what an overriding-nothing project resolves to, so
            # the projects that inherit it are reported. Treating a factory
            # default as "no reference" is the blind spot this scan exists to fix:
            # three real studies inherit cutadapt.primer_pairs from the factory.
            mkpath(joinpath(cfgdir, "defaults"))
            write(joinpath(cfgdir, "defaults", "pipeline.yml"), "cutadapt:\n  primer_pairs:\n    - P_factory\n")
            rm(joinpath(cfgdir, "pipeline.yml"); force=true)
            write(joinpath(cfgdir, "pipeline.yml"), "cutadapt:\n  cores: 4\n")
            @test SV._cascade_refs("cutadapt.primer_pairs")["P_factory"] == ["StudyA"]
            @test !("factory" in SV._cascade_refs("cutadapt.primer_pairs")["P_factory"])

            # An explicit null OVERRIDES to null; it does not inherit. Only an
            # absent key inherits the ancestor's value, so a study that sets the
            # key to null must not be reported under the factory value it would
            # otherwise have inherited.
            write(joinpath(studydir, "pipeline.yml"), "cutadapt:\n  primer_pairs: ~\n")
            refs = SV._cascade_refs("cutadapt.primer_pairs")
            @test !("StudyA" in get(refs, "P_factory", String[]))
            @test !any(names -> "StudyA" in names, values(refs))

            # Deepest wins: a project overriding the inherited value is reported
            # against its own value, not the inherited one.
            write(joinpath(studydir, "pipeline.yml"), "cutadapt:\n  primer_pairs:\n    - P_own\n")
            refs = SV._cascade_refs("cutadapt.primer_pairs")
            @test refs["P_own"] == ["StudyA"]
            @test !haskey(refs, "P_factory")

            # A scalar key contributes itself, so the one scan serves both
            # cutadapt.primer_pairs (a list) and dada2.taxonomy.database (a scalar).
            write(joinpath(cfgdir, "defaults", "pipeline.yml"),
                  "dada2:\n  taxonomy:\n    database: pr2\n")
            @test SV._cascade_refs("dada2.taxonomy.database")["pr2"] == ["StudyA"]

            # A malformed or non-mapping pipeline.yml owned by a directory in
            # the walked tree is treated as absent (not fatal), so the
            # offending project falls back to whatever it would otherwise
            # inherit; it does not stop a good sibling study resolving
            # correctly, nor block every primer save with a 500. A sibling
            # study with its own valid override proves the scan keeps working
            # around the bad file.
            gooddir = joinpath(tmp, "data", "StudyGood")
            mkpath(gooddir)
            write(joinpath(gooddir, "pipeline.yml"), "cutadapt:\n  primer_pairs:\n    - P_good\n")

            write(joinpath(studydir, "pipeline.yml"), "cutadapt: [unterminated\n")
            refs = SV._cascade_refs("cutadapt.primer_pairs")
            @test refs["P_good"] == ["StudyGood"]
            @test !haskey(refs, "P_own")
            @test SV._pair_pipeline_refs_removed(doc, current) isa Vector

            write(joinpath(studydir, "pipeline.yml"), "- a bare list\n- not a mapping\n")
            refs = SV._cascade_refs("cutadapt.primer_pairs")
            @test refs["P_good"] == ["StudyGood"]
            @test !haskey(refs, "P_own")

            # A scalar value, unlike the two cases above, is well-formed YAML and
            # is NOT skipped: under the new semantics it contributes itself
            # rather than being dropped as if the file were unreadable.
            write(joinpath(studydir, "pipeline.yml"), "cutadapt:\n  primer_pairs: not_a_list\n")
            refs = SV._cascade_refs("cutadapt.primer_pairs")
            @test refs["not_a_list"] == ["StudyA"]
            @test refs["P_good"] == ["StudyGood"]
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## config.jl: malformed pipeline.yml in a RUN directory does not throw
    # (Finding A regression). _run_names/_group_names/_group_run_names call
    # _is_pooled, which reads pipeline.yml unguarded, so a study with no
    # subdirectories (as above) never reaches that path. Here StudyA has a
    # real run subdirectory, so _run_names is actually exercised, and its
    # pipeline.yml is malformed. A good sibling study must still resolve
    # correctly in the same scan.
    @testset "cascade refs run-directory malformed file" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            cfgdir = joinpath(tmp, "config")
            mkpath(joinpath(cfgdir, "defaults"))
            write(joinpath(cfgdir, "defaults", "pipeline.yml"),
                  "cutadapt:\n  primer_pairs:\n    - P_factory\n")

            bad_run = joinpath(tmp, "data", "StudyA", "run_1")
            mkpath(bad_run)
            write(joinpath(bad_run, "sample_R1.fastq.gz"), "")
            write(joinpath(bad_run, "pipeline.yml"), "cutadapt: [unterminated\n")

            good_run = joinpath(tmp, "data", "StudyGood", "run_1")
            mkpath(good_run)
            write(joinpath(good_run, "sample_R1.fastq.gz"), "")
            write(joinpath(good_run, "pipeline.yml"),
                  "cutadapt:\n  primer_pairs:\n    - P_good\n")

            refs = SV._cascade_refs("cutadapt.primer_pairs")
            @test refs["P_good"] == ["StudyGood/run_1"]
            @test refs["P_factory"] == ["StudyA/run_1"]
            @test !haskey(refs, "P_own")
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## config.jl: an unreadable directory under data/ must not block a save.
    # walkdir defaults to onerror=throw, so one 0700 directory made a 500 of
    # EVERY databases save: _database_warnings calls _cascade_refs
    # unconditionally, and a shared academic server acquires such a directory
    # readily. Every other hazard in that function was already guarded; this
    # was the one that bypassed them.
    #
    # Guarded on euid: root can read any directory regardless of its mode, so
    # the fixture cannot make the failure happen there.
    if ccall(:geteuid, Cint, ()) != 0
        @testset "cascade refs unreadable directory" begin
            tmp = mktempdir()
            locked = joinpath(tmp, "data", "StudyLocked")
            old_root = SV.ServerState._root[]
            try
                SV.ServerState.set_root!(tmp)
                cfgdir = joinpath(tmp, "config")
                mkpath(joinpath(cfgdir, "defaults"))
                write(joinpath(cfgdir, "defaults", "pipeline.yml"),
                      "dada2:\n  taxonomy:\n    database: pr2\n")

                good = joinpath(tmp, "data", "StudyGood")
                mkpath(good)
                write(joinpath(good, "pipeline.yml"),
                      "dada2:\n  taxonomy:\n    database: pr2\n")

                mkpath(locked)
                write(joinpath(locked, "pipeline.yml"),
                      "dada2:\n  taxonomy:\n    database: pr2\n")
                chmod(locked, 0o000)

                # The scan completes, skipping what it may not read, and the
                # readable sibling still resolves correctly.
                refs = SV._cascade_refs("dada2.taxonomy.database")
                @test refs["pr2"] == ["StudyGood"]
            finally
                # Restore the mode before rm, or the cleanup cannot descend either.
                isdir(locked) && chmod(locked, 0o700)
                SV.ServerState.set_root!(old_root)
                rm(tmp; recursive=true, force=true)
            end
        end
    end

    ## databases.jl: whole-document view and edit
    @testset "databases document" begin
        tmp = mktempdir()
        old_root = SV.ServerState._root[]
        try
            SV.ServerState.set_root!(tmp)
            cfgdir = joinpath(tmp, "config"); mkpath(cfgdir)
            datadir = joinpath(tmp, "data");  mkpath(datadir)
            dbpath = joinpath(cfgdir, "databases.yml")

            write(dbpath, """
            databases:
              dir: ./databases
              pr2:
                dada2:
                  uri: "https://example.org/v5.1.1/pr2_version_5.1.1_SSU_dada2.fasta.gz"
                vsearch:
                  uri: "https://example.org/v5.1.1/pr2_version_5.1.1_SSU_taxo_long.fasta.gz"
                levels:
                  - Domain
                  - Genus
                vsearch_format: pr2
                corrections: []
            """)

            canonical() = SV.DatabasesLibrary.load(dbpath)

            # A malformed body is a plausible client bug behind a Save button and
            # deserves an actionable 400, not a bare 500.
            @test SV._databases_body("not json").status == 400
            @test SV._databases_body("[1,2]").status == 400

            # An unreadable file is a 400 naming the file, and the file is left
            # exactly as it was: we refuse the write rather than let a corrupt
            # file be overwritten from an empty editor.
            before = read(dbpath, String)
            write(dbpath, "databases: [unterminated\n")
            @test SV._read_databases().status == 400
            @test read(dbpath, String) == "databases: [unterminated\n"
            write(dbpath, before)

            # Removing a database that every project resolves to warns and names
            # the projects, and the removal is ALLOWED.
            mkpath(joinpath(datadir, "StudyA"))
            write(joinpath(datadir, "StudyA", "pipeline.yml"), "dada2:\n  taxonomy:\n    database: pr2\n")
            doc = canonical()
            emptied = Dict{String,Any}("dir" => doc["dir"], "databases" => Any[])
            warns = SV._database_warnings(emptied, doc)
            removed = filter(w -> w["kind"] == "database_removed", warns)
            @test length(removed) == 1
            @test removed[1]["database"] == "pr2"
            @test "StudyA" in removed[1]["used_by"]

            # Changing levels on a database in use warns: its stored results no
            # longer match its config.
            changed = deepcopy(doc)
            changed["databases"][1]["levels"] = Any["Domain"]
            lw = filter(w -> w["kind"] == "levels_changed", SV._database_warnings(changed, doc))
            @test length(lw) == 1
            @test "StudyA" in lw[1]["used_by"]

            # Both URIs from one release: no mismatch warning.
            @test isempty(filter(w -> w["kind"] == "release_mismatch", SV._database_warnings(doc, doc)))

            # Disagreeing releases warn. The consensus rank compares DADA2 and
            # VSEARCH labels for string equality, so a cross-release pair scores
            # genuine agreements as disagreements.
            mixed = deepcopy(doc)
            mixed["databases"][1]["vsearch"]["uri"] = "https://example.org/v5.1.0/pr2_version_5.1.0_SSU_taxo_long.fasta.gz"
            rw = filter(w -> w["kind"] == "release_mismatch", SV._database_warnings(mixed, mixed))
            @test length(rw) == 1
            @test rw[1]["database"] == "pr2"

            # A rule violation is a 400 and the file is untouched.
            before2 = read(dbpath, String)
            bad = deepcopy(doc)
            bad["databases"][1]["vsearch_format"] = "PR2"
            @test SV._save_databases(bad).status == 400
            @test read(dbpath, String) == before2

            # A valid save round-trips and preserves the native file shape.
            ok = deepcopy(doc)
            ok["databases"][1]["levels"] = Any["Domain", "Genus", "Species"]
            saved = SV._save_databases(ok)
            @test !(saved isa SV.HTTP.Response)
            reloaded = YAML.load_file(dbpath)
            @test reloaded["databases"]["pr2"]["levels"] == Any["Domain", "Genus", "Species"]
            @test haskey(reloaded["databases"], "dir")

            # An explicit `databases: null` in the submitted body must not throw.
            # `get(doc, "databases", Any[])` only falls back to its default when the
            # key is ABSENT; a present-but-null value arrives as `nothing`, and a bare
            # iteration over `nothing` raises MethodError. This is a write gate behind
            # a Save button, so a hostile or malformed body must yield either a 400 or
            # a clean save, never a bare 500. `no_refs` (no databases, so no key can
            # be "removed") isolates these assertions from the cascade-ref warnings
            # exercised above.
            no_refs = Dict{String,Any}("dir" => "./databases", "databases" => Any[])
            _clean_or_400(result) = result isa SV.HTTP.Response ? result.status == 400 : true

            null_body = SV._databases_body("""{"dir": "./databases", "databases": null}""")
            @test !(null_body isa SV.HTTP.Response)
            @test SV._database_warnings(null_body, no_refs) == Any[]
            @test _clean_or_400(SV._save_databases(null_body))

            # A non-vector `databases` (a scalar, and a mapping) must likewise be
            # handled without throwing: only a real vector is iterated, anything else
            # degrades to "no entries" rather than raising.
            scalar_body = SV._databases_body("""{"dir": "./databases", "databases": "oops"}""")
            @test SV._database_warnings(scalar_body, no_refs) == Any[]
            @test _clean_or_400(SV._save_databases(scalar_body))

            mapping_body = SV._databases_body("""{"dir": "./databases", "databases": {"pr2": {}}}""")
            @test SV._database_warnings(mapping_body, no_refs) == Any[]
            @test _clean_or_400(SV._save_databases(mapping_body))
        finally
            SV.ServerState.set_root!(old_root)
            rm(tmp; recursive=true, force=true)
        end
    end

    ## A local: path the write gate must no longer judge. Whether the file is
    # presently on disk is a fact about the machine, not about the document, so
    # it belongs to the environment validator; _validate_databases still reports
    # it, and test_validation.jl covers it there, including the NUL and EACCES
    # paths that isfile cannot answer. Here the concern is only that the SAVE
    # route no longer rejects a document for it: a save carries the whole
    # document, so one stale override used to lock the entire editor, and the
    # 400 disclosed to any client whether an arbitrary server path existed.
    @testset "save route admits a local: file that is not there" begin
        tmp = mktempdir()
        old_root = SV.ServerState._root[]
        try
            SV.ServerState.set_root!(tmp)
            cfgdir = joinpath(tmp, "config"); mkpath(cfgdir)
            dbpath = joinpath(cfgdir, "databases.yml")
            write(dbpath, """
            databases:
              dir: ./databases
              pr2:
                dada2:
                  local: /no/such/file
                vsearch:
                  uri: "https://example.org/b.gz"
                levels:
                  - Domain
                vsearch_format: pr2
                corrections: []
            """)

            body = SV._databases_body("""
                {"dir": "./databases",
                 "databases": [{"key": "pr2", "label": "",
                                "dada2":   {"uri": "", "local": "/no/such/file", "remote_path": null},
                                "vsearch": {"uri": "https://example.org/b.gz", "local": null},
                                "levels": ["Domain", "Genus"], "vsearch_format": "pr2",
                                "corrections": []}]}
                """)
            @test !(body isa SV.HTTP.Response)
            # The save must SUCCEED, not merely avoid a 500: the whole point is
            # that an edit elsewhere in the document is no longer held hostage by
            # a local: whose file has moved.
            saved = SV._save_databases(body)
            @test !(saved isa SV.HTTP.Response)
            @test YAML.load_file(dbpath)["databases"]["pr2"]["levels"] == Any["Domain", "Genus"]
        finally
            SV.ServerState.set_root!(old_root)
            rm(tmp; recursive=true, force=true)
        end
    end

end
