@testset "Tools - get_primer_args mode dispatch" begin
    # Write a self-contained primers fixture - avoids depending on gitignored config/primers.yml
    primers_path = joinpath(tempdir(), "test_primers_$(getpid()).yml")
    write(primers_path, """
Forward:
  FwdPrimer: "AAAA"
Reverse:
  RevPrimer: "TTTT"
Pairs:
  - TestPair:
    - FwdPrimer
    - RevPrimer
""")

    try
        @testset "paired mode emits -g and -G" begin
            args = Tools.get_primer_args(["TestPair"], primers_path; mode="paired")
            @test occursin("-g AAAA", args)
            @test occursin("-G TTTT", args)
        end

        @testset "forward mode emits only -g, no -G" begin
            args = Tools.get_primer_args(["TestPair"], primers_path; mode="forward")
            @test occursin("-g AAAA", args)
            @test !occursin("-G", args)
        end

        @testset "reverse mode emits -g for reverse primer only" begin
            args = Tools.get_primer_args(["TestPair"], primers_path; mode="reverse")
            @test occursin("-g TTTT", args)
            @test !occursin("-G", args)
            @test !occursin("AAAA", args)
        end

        @testset "default mode is paired" begin
            args_default = Tools.get_primer_args(["TestPair"], primers_path)
            args_paired  = Tools.get_primer_args(["TestPair"], primers_path; mode="paired")
            @test args_default == args_paired
        end
    finally
        rm(primers_path; force=true)
    end
end
