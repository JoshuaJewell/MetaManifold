@testset "Validation" begin

    @testset "_validate_primers - valid" begin
        tmp = tempname() * ".yml"
        write(tmp, """
Forward:
  EMP515F: "GTGYCAGCMGCCGCGGTAA"
Reverse:
  EMP806R: "GGACTACNVGGGTWTCTAAT"
Pairs:
  - EMP:
    - EMP515F
    - EMP806R
""")
        errors = Validation.ValidationError[]
        Validation._validate_primers(errors, tmp)
        rm(tmp)
        @test isempty(errors)
    end

    @testset "_validate_primers - unknown pair member" begin
        tmp = tempname() * ".yml"
        write(tmp, """
Forward:
  EMP515F: "GTGYCAGCMGCCGCGGTAA"
Reverse:
  EMP806R: "GGACTACNVGGGTWTCTAAT"
Pairs:
  - EMP:
    - EMP515F
    - UnknownR
""")
        errors = Validation.ValidationError[]
        Validation._validate_primers(errors, tmp)
        rm(tmp)
        @test any(e -> occursin("UnknownR", e.message), errors)
    end

    @testset "_validate_primers - invalid base" begin
        tmp = tempname() * ".yml"
        write(tmp, """
Forward:
  BadF: "ATCGXYZ"
Reverse:
  GoodR: "ATCG"
Pairs: []
""")
        errors = Validation.ValidationError[]
        Validation._validate_primers(errors, tmp)
        rm(tmp)
        @test any(e -> occursin("invalid bases", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - valid" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "dada2"    => Dict(
                "filter_trim" => Dict("trunc_len" => [240, 160], "min_len" => 100, "max_ee" => [2, 2]),
                "taxonomy"    => Dict("database" => "pr2", "multithread" => 4),
            ),
            "vsearch"  => Dict("identity" => 0.75, "query_cov" => 0.8),
            "cdhit"    => Dict("identity" => 0.97),
            "swarm"    => Dict("differences" => 1, "identity" => 0.97),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test isempty(errors)
    end

    @testset "_validate_pipeline_cfg - trunc_len < min_len" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "dada2"    => Dict(
                "filter_trim" => Dict("trunc_len" => [80, 80], "min_len" => 100, "max_ee" => [2, 2]),
            ),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("trunc_len", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - identity out of range" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "vsearch"  => Dict("identity" => 1.5),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("identity", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - empty primer_pairs" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => [], "min_length" => 200),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("primer_pairs", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - denovo_method whitelist" begin
        # Valid values pass.
        for v in Validation.DENOVO_METHODS
            cfg = Dict(
                "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
                "asv"      => Dict("denovo_method" => v),
            )
            errors = Validation.ValidationError[]
            Validation._validate_pipeline_cfg(errors, cfg, "test")
            @test !any(e -> occursin("denovo_method", e.message), errors)
        end

        # An unrecognised method (the canonical scenario: capitalised typo) is rejected.
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "asv"      => Dict("denovo_method" => "Consensus"),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("denovo_method", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - multithread accepts Bool and positive Integer" begin
        for v in (true, false, 1, 4)
            cfg = Dict(
                "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
                "dada2"    => Dict("taxonomy" => Dict("multithread" => v)),
            )
            errors = Validation.ValidationError[]
            Validation._validate_pipeline_cfg(errors, cfg, "test")
            @test !any(e -> occursin("multithread", e.message), errors)
        end
    end

    @testset "_validate_pipeline_cfg - multithread rejects string and float" begin
        for v in ("4", 4.0, 0)
            cfg = Dict(
                "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
                "dada2"    => Dict("taxonomy" => Dict("multithread" => v)),
            )
            errors = Validation.ValidationError[]
            Validation._validate_pipeline_cfg(errors, cfg, "test")
            @test any(e -> occursin("multithread", e.message), errors)
        end
    end

    @testset "validate_environment - missing tools config" begin
        n = Validation.validate_environment(
            ProjectCtx[],
            "/nonexistent/databases.yml",
            "/nonexistent/tools.yml"
        )
        @test n > 0
    end

    @testset "validate_environment - empty tools config" begin
        mktempdir() do tmp
            tools_cfg = joinpath(tmp, "tools.yml")
            write(tools_cfg, "")
            db_cfg = joinpath(tmp, "databases.yml")
            write(db_cfg, "databases: {}")
            n = Validation.validate_environment(ProjectCtx[], db_cfg, tools_cfg)
            # Empty tools.yml is not a valid Dict; expect at least 1 error
            @test n > 0
        end
    end

end
