@testset "Config hashing and staleness" begin

    @testset "stage_sections" begin
        @test Config.stage_sections(:cutadapt) == "seed,subsample_n,cutadapt"
        @test Config.stage_sections(:dada2_filter_trim) == "dada2.file_patterns,dada2.filter_trim"
        @test Config.stage_sections(:merge_taxa) == "merge_taxa,vsearch.enabled,swarm.enabled,dada2.taxonomy.enabled"
        @test_throws ErrorException Config.stage_sections(:nonexistent_stage)
    end

    @testset "_cascade_paths" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))

        # Study == project (flat project)
        paths = Config._cascade_paths(config_dir, joinpath(dir, "data", "study"),
                                       joinpath(dir, "data", "study"))
        @test length(paths) == 3
        @test paths[1] == joinpath(config_dir, "defaults", "pipeline.yml")
        @test paths[2] == joinpath(config_dir, "pipeline.yml")

        # Nested: study -> group -> run
        paths2 = Config._cascade_paths(config_dir, joinpath(dir, "data", "study"),
                                        joinpath(dir, "data", "study", "group", "run"))
        @test length(paths2) == 5  # defaults, config, study, group, run
        @test endswith(paths2[3], joinpath("study", "pipeline.yml"))
        @test endswith(paths2[4], joinpath("group", "pipeline.yml"))
        @test endswith(paths2[5], joinpath("run", "pipeline.yml"))

        rm(dir; recursive=true)
    end

    @testset "_canonical deterministic ordering" begin
        d1 = Dict("b" => 2, "a" => 1)
        d2 = Dict("a" => 1, "b" => 2)
        @test Config._canonical(d1) == Config._canonical(d2)

        nested = Dict("x" => Dict("b" => 2, "a" => 1))
        @test Config._canonical(nested) == "{x:{a:1,b:2}}"
        @test Config._canonical([1, 2, 3]) == "[1,2,3]"
        @test Config._canonical(nothing) == "null"
        @test Config._canonical("hello") == "hello"
    end

    @testset "_get_nested" begin
        cfg = Dict("dada2" => Dict("filter_trim" => Dict("trunc_len" => [220, 220])))
        @test Config._get_nested(cfg, "dada2") == cfg["dada2"]
        @test Config._get_nested(cfg, "dada2.filter_trim") == cfg["dada2"]["filter_trim"]
        @test Config._get_nested(cfg, "dada2.filter_trim.trunc_len") == [220, 220]
        @test isnothing(Config._get_nested(cfg, "nonexistent"))
        @test isnothing(Config._get_nested(cfg, "dada2.nonexistent"))
    end

    @testset "_section_hash consistent" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "config.yml")
        write(cfg_path, "cutadapt:\n  min_length: 200\n  cores: 0\n")

        h1 = Config._section_hash(cfg_path, "cutadapt")
        h2 = Config._section_hash(cfg_path, "cutadapt")
        @test h1 == h2
        @test length(h1) == 64  # SHA-256 hex

        # Different section -> different hash
        write(cfg_path, "cutadapt:\n  min_length: 200\ndada2:\n  verbose: true\n")
        h_cut = Config._section_hash(cfg_path, "cutadapt")
        h_dada = Config._section_hash(cfg_path, "dada2")
        @test h_cut != h_dada

        rm(dir; recursive=true)
    end

    @testset "_section_stale and _write_section_hash round-trip" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "config.yml")
        hash_file = joinpath(dir, "stage.hash")
        write(cfg_path, "cutadapt:\n  min_length: 200\n")

        # No hash file -> stale
        @test Config._section_stale(cfg_path, "cutadapt", hash_file) == true

        # Write hash -> not stale
        Config._write_section_hash(cfg_path, "cutadapt", hash_file)
        @test Config._section_stale(cfg_path, "cutadapt", hash_file) == false

        # Change config -> stale again
        write(cfg_path, "cutadapt:\n  min_length: 150\n")
        @test Config._section_stale(cfg_path, "cutadapt", hash_file) == true

        rm(dir; recursive=true)
    end

    @testset "_stale_keys identifies changed keys" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "config.yml")
        hash_file = joinpath(dir, "stage.hash")

        write(cfg_path, "cutadapt:\n  min_length: 200\n  cores: 0\n")
        Config._write_section_hash(cfg_path, "cutadapt", hash_file)

        @test isempty(Config._stale_keys(cfg_path, "cutadapt", hash_file))

        write(cfg_path, "cutadapt:\n  min_length: 150\n  cores: 0\n")
        changed = Config._stale_keys(cfg_path, "cutadapt", hash_file)
        @test "cutadapt.min_length" in changed
        @test "cutadapt.cores" ∉ changed

        # Add a new key
        write(cfg_path, "cutadapt:\n  min_length: 150\n  cores: 0\n  overlap: 10\n")
        changed2 = Config._stale_keys(cfg_path, "cutadapt", hash_file)
        @test "cutadapt.overlap" in changed2

        # Remove a key
        write(cfg_path, "cutadapt:\n  cores: 0\n")
        changed3 = Config._stale_keys(cfg_path, "cutadapt", hash_file)
        @test "cutadapt.min_length" in changed3

        rm(dir; recursive=true)
    end

    @testset "_stale_keys fallback without companion file" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "config.yml")
        hash_file = joinpath(dir, "stage.hash")

        write(cfg_path, "cutadapt:\n  min_length: 200\n")
        # Write only the hash file, not the .values companion
        write(hash_file, "somehash")

        result = Config._stale_keys(cfg_path, "cutadapt", hash_file)
        @test result == ["cutadapt"]

        rm(dir; recursive=true)
    end

    @testset "write_run_config" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))

        # Create defaults
        write(joinpath(config_dir, "defaults", "pipeline.yml"),
            "cutadapt:\n  min_length: 200\n  cores: 0\n")

        # Create study-level override
        data_dir = joinpath(dir, "data", "study", "run")
        mkpath(data_dir)
        write(joinpath(dir, "data", "study", "pipeline.yml"),
            "cutadapt:\n  min_length: 150\n")

        # Create project dir
        proj_dir = joinpath(dir, "projects", "study", "run")
        mkpath(proj_dir)

        ctx = ProjectCtx(proj_dir, config_dir, data_dir,
                          joinpath(dir, "projects", "study"),
                          joinpath(dir, "data", "study"))

        path = Config.write_run_config(ctx)
        @test isfile(path)
        @test endswith(path, "run_config.yml")

        merged = YAML.load_file(path)
        @test merged["cutadapt"]["min_length"] == 150  # overridden
        @test merged["cutadapt"]["cores"] == 0          # inherited

        rm(dir; recursive=true)
    end

end
