@testset "Config" begin

    @testset "_deep_merge" begin
        base  = Dict("a" => 1, "b" => Dict("x" => 10, "y" => 20))
        patch = Dict("b" => Dict("y" => 99, "z" => 30), "c" => 3)
        result = Config._deep_merge(base, patch)

        @test result["a"] == 1          # unchanged
        @test result["c"] == 3          # new key
        @test result["b"]["x"] == 10    # nested unchanged
        @test result["b"]["y"] == 99    # nested overridden
        @test result["b"]["z"] == 30    # nested new key

        # Arrays are replaced, not merged
        base2  = Dict("arr" => [1, 2, 3])
        patch2 = Dict("arr" => [4, 5])
        @test Config._deep_merge(base2, patch2)["arr"] == [4, 5]

        # Original dicts unmodified
        @test base["b"]["y"] == 20
    end

    @testset "load_merged_config cascade" begin
        dir = mktempdir()
        # Write a minimal defaults file
        defaults = joinpath(dir, "defaults.yml")
        write(defaults, "cutadapt:\n  min_length: 200\n  cores: 0\ndada2:\n  verbose: true\n")
        override = joinpath(dir, "override.yml")
        write(override, "cutadapt:\n  min_length: 150\n")

        cfg = Config.load_merged_config([defaults, override])
        @test cfg["cutadapt"]["min_length"] == 150   # overridden
        @test cfg["cutadapt"]["cores"]      == 0     # inherited
        @test cfg["dada2"]["verbose"]       == true  # inherited
    end

    @testset "default analysis exclude_categories" begin
        defaults_path = joinpath(@__DIR__, "..", "..", "config", "defaults", "pipeline.yml")
        defaults = YAML.load_file(defaults_path)
        @test haskey(defaults, "annotation")
        @test defaults["annotation"]["max_rank"] == "genus"
        @test haskey(defaults, "analysis")
        @test haskey(defaults["analysis"], "exclude_categories")
        excl = defaults["analysis"]["exclude_categories"]
        @test length(excl) == 1
        @test excl[1]["set"] == "contamination"
        @test excl[1]["category"] == "Contaminant"
        # Composition is intentionally left out so its chart shows the full make-up.
        @test excl[1]["apply_to"] == ["diversity", "taxa", "venn"]
        @test !("composition" in excl[1]["apply_to"])
    end

    @testset "tagging config defaults" begin
        cfg = MetaManifold.Config.load_merged_config([joinpath(@__DIR__, "..", "..", "config", "defaults", "pipeline.yml")])
        @test haskey(cfg, "tagging")
        @test cfg["tagging"]["source"] == "VSEARCH"
        @test cfg["tagging"]["max_x"] == -1
        @test cfg["tagging"]["category_sets"] == ["default"]
    end

end
