@testset "PipelineLog" begin

    @testset "reset_log creates log file" begin
        dir = mktempdir()
        PipelineLog.reset_log(dir)
        log_path = joinpath(dir, "pipeline.log")
        @test isfile(log_path)
        content = read(log_path, String)
        @test startswith(content, "Pipeline log started")
        rm(dir; recursive=true)
    end

    @testset "pipeline_log appends timestamped messages" begin
        dir = mktempdir()
        PipelineLog.reset_log(dir)
        PipelineLog.pipeline_log(dir, "Test message 1")
        PipelineLog.pipeline_log(dir, "Test message 2")
        content = read(joinpath(dir, "pipeline.log"), String)
        @test occursin("Test message 1", content)
        @test occursin("Test message 2", content)
        lines = split(strip(content), '\n')
        @test length(lines) == 3  # header + 2 messages
        rm(dir; recursive=true)
    end

    @testset "pipeline_log with ProjectCtx" begin
        dir = mktempdir()
        ctx = ProjectCtx(dir, "", "", "", "")
        PipelineLog.reset_log(ctx)
        PipelineLog.pipeline_log(ctx, "via context")
        content = read(joinpath(dir, "pipeline.log"), String)
        @test occursin("via context", content)
        rm(dir; recursive=true)
    end

    @testset "log_written records SHA-256" begin
        dir = mktempdir()
        PipelineLog.reset_log(dir)
        test_file = joinpath(dir, "test_output.csv")
        write(test_file, "hello world\n")
        PipelineLog.log_written(dir, test_file)
        content = read(joinpath(dir, "pipeline.log"), String)
        @test occursin("Written:", content)
        @test occursin("sha256:", content)
        # SHA-256 hex is 64 chars
        m = match(r"sha256:([0-9a-f]+)", content)
        @test !isnothing(m)
        @test length(m[1]) == 64
        rm(dir; recursive=true)
    end

    @testset "finalise_log appends tool logs" begin
        dir = mktempdir()
        PipelineLog.reset_log(dir)
        PipelineLog.pipeline_log(dir, "Stage complete")

        # Create a fake tool log
        mkpath(joinpath(dir, "cutadapt", "logs"))
        write(joinpath(dir, "cutadapt", "logs", "cutadapt_primer_trimming_stats.txt"),
              "Trimmed: 100 reads\nRetained: 95 reads\n")

        ctx = ProjectCtx(dir, "", "", "", "")
        PipelineLog.finalise_log(ctx)

        content = read(joinpath(dir, "pipeline.log"), String)
        @test occursin("Tool logs appended", content)
        @test occursin("Trimmed: 100 reads", content)
        @test occursin("End of tool logs", content)
        rm(dir; recursive=true)
    end

    ## Drift guard
    # A realistic populated run directory. Every path here was observed in a real
    # run (projects/Nutria_CvL/Multiplex, read-only) or is written by a code path
    # that run did not exercise. The guard below asserts that the registry accounts
    # for all of them, so a newly added log cannot slip into the pipeline unnoticed
    # the way the whole SWARM branch once did.
    function _populate_run_dir(dir::String)
        # Log, stats, and hash files the pipeline itself writes.
        pipeline_written = [
            "QC/logs/fastqc.log",
            "QC/logs/multiqc.log",
            "QC/config.hash",
            "cutadapt/logs/cutadapt.log",
            "cutadapt/logs/cutadapt_primer_trimming_stats.txt",
            "cutadapt/logs/cutadapt_trimmed_percentage.txt",
            "cutadapt/config.hash",
            "dada2/Logs/prefilter_qc.log",
            "dada2/Logs/filter_trim.log",
            "dada2/Logs/learn_errors.log",
            "dada2/Logs/denoise.log",
            "dada2/Logs/filter_length.log",
            "dada2/Logs/chimera_removal.log",
            "dada2/Logs/assign_taxonomy.log",
            "dada2/Checkpoints/prefilter_qc.hash",
            "dada2/Checkpoints/filter_trim.hash",
            "dada2/Checkpoints/learn_errors.hash",
            "dada2/Checkpoints/denoise.hash",
            "dada2/Checkpoints/filter_length.hash",
            "dada2/Checkpoints/chimera_removal.hash",
            "dada2/Checkpoints/assign_taxonomy.hash",
            "vsearch/logs/vsearch.log",
            "vsearch/config.hash",
            "cdhit/logs/cdhit.log",
            "cdhit/config.hash",
            "swarm/logs/filter_ns.log",
            "swarm/logs/swarm.log",
            "swarm/logs/rename.log",
            "swarm/config.hash",
            "swarm/vsearch/logs/vsearch.log",
            "swarm/vsearch/config.hash",
            "merged/config.hash",
            "merged/config_otu.hash",
        ]
        # Files the scan sweeps in but the registry deliberately excludes.
        excluded = [
            "pipeline.log",
            "QC/config.hash.values",
            "cutadapt/config.hash.values",
            "swarm/config.hash.values",
            "dada2/Checkpoints/denoise.hash.values",
            "merged/config_otu.hash.values",
            "QC/multiqc_data/multiqc.log",
            "QC/multiqc_data/multiqc_general_stats.txt",
            "dada2/Tables/pipeline_stats.csv",
            "dada2/Checkpoints/checkpoint.RData",
            "dada2/Checkpoints/ckpt_denoise.RData",
        ]
        # Data outputs, which the scan must not mistake for logs.
        outputs = [
            "run_config.yml",
            "dada2/Tables/asvs.fasta",
            "swarm/otu_table.csv",
            "QC/multiqc_report.html",
        ]
        for rel in vcat(pipeline_written, excluded, outputs)
            path = joinpath(dir, rel)
            mkpath(dirname(path))
            write(path, "contents of $rel\n")
        end
        return pipeline_written, excluded, outputs
    end

    @testset "log registry does not drift" begin
        dir = mktempdir()
        pipeline_written, excluded, outputs = _populate_run_dir(dir)

        # Nothing the pipeline writes may be absent from the registry without being
        # excluded on purpose. This is the assertion the whole guard exists for.
        @test isempty(PipelineLog.unregistered_logs(dir))

        registered = [rel for (_, rel) in PipelineLog._TOOL_LOG_FILES]
        # The registry carries no phantom: every entry is a file a real run writes.
        @test sort(registered) == sort(pipeline_written)

        scanned = PipelineLog.scan_log_files(dir)
        # Exclusions are matched, not merely absent from the scan.
        for rel in excluded
            @test rel in scanned
            @test PipelineLog.log_excluded(rel)
        end
        # Data outputs are not logs and must never be swept in.
        for rel in outputs
            @test !(rel in scanned)
        end
        rm(dir; recursive=true)
    end

    @testset "drift guard fails on an unregistered log" begin
        dir = mktempdir()
        _populate_run_dir(dir)
        # Stand in for a future stage that writes a log and forgets the registry.
        mkpath(joinpath(dir, "swarm", "logs"))
        write(joinpath(dir, "swarm", "logs", "chimera_check.log"), "new stage\n")

        drifted = PipelineLog.unregistered_logs(dir)
        @test drifted == ["swarm/logs/chimera_check.log"]
        rm(dir; recursive=true)
    end

    @testset "finalise_log carries the SWARM branch" begin
        dir = mktempdir()
        PipelineLog.reset_log(dir)
        mkpath(joinpath(dir, "swarm", "logs"))
        write(joinpath(dir, "swarm", "logs", "swarm.log"), "Swarm 3.1.6\n")
        write(joinpath(dir, "swarm", "logs", "filter_ns.log"), "vsearch fastx_filter\n")
        write(joinpath(dir, "swarm", "logs", "rename.log"), "")
        mkpath(joinpath(dir, "swarm", "vsearch", "logs"))
        write(joinpath(dir, "swarm", "vsearch", "logs", "vsearch.log"), "OTU taxonomy\n")

        PipelineLog.finalise_log(ProjectCtx(dir, "", "", "", ""))
        content = read(joinpath(dir, "pipeline.log"), String)

        @test occursin("swarm/logs/swarm.log", content)
        @test occursin("Swarm 3.1.6", content)
        @test occursin("vsearch fastx_filter", content)
        @test occursin("swarm/vsearch/logs/vsearch.log", content)
        @test occursin("OTU taxonomy", content)
        rm(dir; recursive=true)
    end

    @testset "reset_tool_logs truncates and creates parents" begin
        dir = mktempdir()
        log_a = joinpath(dir, "swarm", "logs", "swarm.log")
        log_b = joinpath(dir, "swarm", "logs", "rename.log")

        PipelineLog.reset_tool_logs(log_a, log_b)
        @test isfile(log_a) && isfile(log_b)

        write(log_a, "stale output from the previous run\n")
        PipelineLog.reset_tool_logs(log_a)
        @test read(log_a, String) == ""
        rm(dir; recursive=true)
    end

    @testset "log_command records the resolved command behind the marker" begin
        dir      = mktempdir()
        log_path = joinpath(dir, "tool.log")
        write(log_path, "header\n")

        PipelineLog.log_command("vsearch --usearch_global q.fa --db ref.fa", log_path)
        PipelineLog.log_command("cd-hit-est -i q.fa -o out.fa -c 0.97", log_path)
        content = read(log_path, String)

        # The marker is fixed so a single grep recovers every command a run issued.
        cmd_lines = filter(l -> startswith(l, "[MetaManifold] cmd: "), readlines(log_path))
        @test length(cmd_lines) == 2
        @test cmd_lines[1] == "[MetaManifold] cmd: vsearch --usearch_global q.fa --db ref.fa"
        @test occursin(r"\[MetaManifold\] command at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", content)
        # Appends rather than truncating: the header and first command both survive.
        @test occursin("header", content)
        @test occursin("cd-hit-est -i q.fa", content)
        rm(dir; recursive=true)
    end

    @testset "write_combined_log merges run logs" begin
        study_dir = mktempdir()
        run1_dir = joinpath(study_dir, "run1")
        run2_dir = joinpath(study_dir, "run2")
        mkpath(run1_dir)
        mkpath(run2_dir)

        PipelineLog.reset_log(run1_dir)
        PipelineLog.pipeline_log(run1_dir, "Run 1 done")
        PipelineLog.reset_log(run2_dir)
        PipelineLog.pipeline_log(run2_dir, "Run 2 done")

        ctx1 = ProjectCtx(run1_dir, "", "", study_dir, "")
        ctx2 = ProjectCtx(run2_dir, "", "", study_dir, "")

        path = PipelineLog.write_combined_log([ctx1, ctx2]; study_dir)
        @test isfile(path)
        content = read(path, String)
        @test occursin("Combined pipeline log", content)
        @test occursin("Run 1 done", content)
        @test occursin("Run 2 done", content)
        @test occursin("RUN: run1", content)
        @test occursin("RUN: run2", content)
        rm(study_dir; recursive=true)
    end

end
