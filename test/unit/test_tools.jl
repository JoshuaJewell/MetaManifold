@testset "Tools - _parse_cdhit_clstr" begin
    clstr_path = joinpath(tempdir(), "test_cdhit_$(getpid()).clstr")
    write(clstr_path, """
>Cluster 0
0\t300nt, >seq1... *
1\t295nt, >seq2... at 98.00%
2\t290nt, >seq3... at 97.50%
>Cluster 1
0\t250nt, >seq4... *
>Cluster 2
0\t200nt, >seq5... at 99.00%
1\t210nt, >seq6... *
""")

    try
        rep_map = Tools._parse_cdhit_clstr(clstr_path)

        @test rep_map["seq1"] == "seq1"
        @test rep_map["seq2"] == "seq1"
        @test rep_map["seq3"] == "seq1"
        @test rep_map["seq4"] == "seq4"
        @test rep_map["seq5"] == "seq6"
        @test rep_map["seq6"] == "seq6"
        @test length(rep_map) == 6
    finally
        rm(clstr_path; force=true)
    end
end

@testset "Tools - _collapse_cdhit_counts" begin
    td = mktempdir()
    clstr_path = joinpath(td, "asvs.fasta.clstr")
    counts_path = joinpath(td, "seqtab_nochim.csv")
    out_path = joinpath(td, "collapsed_counts.csv")

    write(clstr_path, """
>Cluster 0
0\t300nt, >seq1... *
1\t295nt, >seq2... at 98.00%
>Cluster 1
0\t250nt, >seq3... *
""")

    write(counts_path, """
SeqName,SampleA,SampleB
seq1,10,20
seq2,5,15
seq3,100,200
""")

    try
        Tools._collapse_cdhit_counts(clstr_path, counts_path, out_path)
        df = CSV.read(out_path, DataFrame)

        @test nrow(df) == 2
        row1 = filter(r -> r.SeqName == "seq1", df)
        @test nrow(row1) == 1
        @test row1[1, :SampleA] == 15
        @test row1[1, :SampleB] == 35

        row3 = filter(r -> r.SeqName == "seq3", df)
        @test nrow(row3) == 1
        @test row3[1, :SampleA] == 100
        @test row3[1, :SampleB] == 200
    finally
        rm(td; recursive=true, force=true)
    end
end

@testset "Tools - _expected_trimmed_count" begin
    # Mirrors the primary-read pattern the cutadapt skip guard builds.
    pat(suffix) = Regex(suffix * raw"[^/]*\.fastq\.gz$")

    # Three paired samples: six raw files (R1 + R2 each).
    all_entries = [
        FastqEntry("/d/s1_R1.fastq.gz", "s1_R1.fastq.gz"),
        FastqEntry("/d/s1_R2.fastq.gz", "s1_R2.fastq.gz"),
        FastqEntry("/d/s2_R1.fastq.gz", "s2_R1.fastq.gz"),
        FastqEntry("/d/s2_R2.fastq.gz", "s2_R2.fastq.gz"),
        FastqEntry("/d/s3_R1.fastq.gz", "s3_R1.fastq.gz"),
        FastqEntry("/d/s3_R2.fastq.gz", "s3_R2.fastq.gz"),
    ]
    r1_only = filter(e -> occursin(pat("_R1"), e.name), all_entries)

    # No-subsample path: selection holds every raw file (R1 + R2). Paired mode
    # writes two trimmed files per sample, so three samples -> six, NOT twelve.
    @test Tools._expected_trimmed_count(all_entries, "paired", pat("_R1")) == 6
    # Subsample path: selection is already primary-only. Same answer either way.
    @test Tools._expected_trimmed_count(r1_only, "paired", pat("_R1")) == 6
    # Single-end modes write one trimmed file per primary read.
    @test Tools._expected_trimmed_count(all_entries, "forward", pat("_R1")) == 3
    @test Tools._expected_trimmed_count(all_entries, "reverse", pat("_R2")) == 3
end

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

@testset "Tools - _run_logged appends and records the command" begin
    td       = mktempdir()
    log_path = joinpath(td, "logs", "tool.log")

    try
        @testset "records the resolved command line and a timestamp" begin
            Tools._run_logged("echo first-run", log_path)
            content = read(log_path, String)

            @test occursin("[MetaManifold] cmd: echo first-run", content)
            @test occursin(r"\[MetaManifold\] command at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", content)
            @test occursin("first-run", content)
            # The command is recorded before the output it produced.
            @test findfirst("cmd: echo first-run", content)[1] <
                  findlast("first-run", content)[1]
        end

        @testset "a second command does not destroy the first" begin
            Tools._run_logged("echo second-run", log_path)
            content = read(log_path, String)

            @test occursin("first-run", content)
            @test occursin("second-run", content)
            @test count(x -> occursin("[MetaManifold] cmd: ", x),
                        split(content, '\n')) == 2
        end

        @testset "failure echoes the log to stderr and rethrows" begin
            fail_log = joinpath(td, "logs", "fail.log")
            err_path = joinpath(td, "stderr.txt")
            open(err_path, "w") do errio
                @test_throws Exception redirect_stderr(errio) do
                    Tools._run_logged("echo doomed && exit 3", fail_log)
                end
            end
            @test occursin("doomed", read(err_path, String))
            # The command survives the failure, which is when it matters most.
            @test occursin("[MetaManifold] cmd: echo doomed && exit 3",
                           read(fail_log, String))
        end
    finally
        rm(td; recursive=true, force=true)
    end
end
