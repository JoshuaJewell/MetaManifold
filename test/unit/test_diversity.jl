@testset "DiversityMetrics" begin

    @testset "richness" begin
        @test richness([1, 2, 3])    == 3
        @test richness([0, 1, 0, 2]) == 2
        @test richness([0, 0, 0])    == 0
        @test richness(Int[])        == 0
        @test richness([5])          == 1
    end

    @testset "shannon" begin
        @test shannon([10]) ≈ 0.0
        @test shannon([0, 0, 0]) ≈ 0.0
        @test shannon([50, 50]) ≈ log(2) atol=1e-10
        @test shannon([25, 25, 25, 25]) ≈ log(4) atol=1e-10
        @test shannon([50, 0, 50]) ≈ log(2) atol=1e-10

        expected = -(0.9*log(0.9) + 0.1*log(0.1))
        @test shannon([90, 10]) ≈ expected atol=1e-10
    end

    @testset "simpson" begin
        @test simpson([100]) ≈ 0.0
        @test simpson([0, 0]) ≈ 0.0
        @test simpson([50, 50]) ≈ 0.5 atol=1e-10
        @test simpson([25, 25, 25, 25]) ≈ 0.75 atol=1e-10
        @test simpson([50, 0, 50]) ≈ 0.5 atol=1e-10

        for counts in ([1,1,1,1,1], [100,1], [1,2,3,4,5])
            d = simpson(counts)
            @test 0 <= d < 1
        end
    end

    @testset "Normalisation" begin

        @testset "rarefy" begin
            mat = [100.0 200.0 300.0;
                   150.0 150.0 200.0]
            depth = 50

            result = rarefy(mat; depth, seed=42)
            @test all(sum(result; dims=2) .≈ Float64(depth))
            @test all(result .== floor.(result))
            @test rarefy(mat; depth, seed=42) == rarefy(mat; depth, seed=42)
            @test rarefy(mat; depth, seed=42) != rarefy(mat; depth, seed=99)
        end

        @testset "normalise_counts" begin
            # 3 samples by 2 features; lib sizes: 300, 400, 100
            mat = [100.0 200.0;
                   300.0 100.0;
                    50.0  50.0]

            # "none": input unchanged, all row indices returned
            r = normalise_counts(mat; method="none", depth=0, seed=1)
            @test r.mat == Matrix{Float64}(mat)
            @test r.kept == [1, 2, 3]

            # "rarefy" depth=0 (auto): resolved depth = min positive lib size = 100
            r_rar = normalise_counts(mat; method="rarefy", depth=0, seed=42)
            @test r_rar.kept == [1, 2, 3]
            @test all(sum(r_rar.mat; dims=2) .≈ 100.0)

            # Fixed depth=150: row 3 (lib_size=100) is below threshold, dropped
            r_drop = normalise_counts(mat; method="rarefy", depth=150, seed=42)
            @test r_drop.kept == [1, 2]
            @test size(r_drop.mat, 1) == 2
            @test all(sum(r_drop.mat; dims=2) .≈ 150.0)

            # Edge: single sample - no crash
            single = reshape([10.0, 20.0, 30.0], 1, 3)
            r_single = normalise_counts(single; method="rarefy", depth=0, seed=42)
            @test r_single.kept == [1]
            @test size(r_single.mat, 1) == 1

            # Edge: all-zero sample is dropped (lib_size=0 < resolved_depth of positive min)
            with_zero = [0.0 0.0; 50.0 50.0]
            r_zero = normalise_counts(with_zero; method="rarefy", depth=0, seed=42)
            @test r_zero.kept == [2]
            @test size(r_zero.mat, 1) == 1
        end

    end  # Normalisation

end
