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

end
