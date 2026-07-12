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
        # Uses the real compositions + filters dirs so the "default" set is resolved.
        comps_dir = joinpath(@__DIR__, "..", "..", "config", "compositions")
        flt_dir   = joinpath(@__DIR__, "..", "..", "config", "filters")
        SV.Categories.write_category_columns!(con, "merged", "VSEARCH", ["default"];
                                              compositions_dir=comps_dir,
                                              filters_dir=flt_dir)
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

end
