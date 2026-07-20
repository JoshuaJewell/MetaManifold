module PipelineLog

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export pipeline_log, log_written, reset_tool_logs, log_command

    using SHA, Dates
    using ..PipelineTypes

    function reset_log(dir::String)
        path = joinpath(dir, "pipeline.log")
        open(path, "w") do io
            println(io, "Pipeline log started ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        end
    end
    reset_log(project::ProjectCtx) = reset_log(project.dir)

    function pipeline_log(dir::String, msg::String)
        open(joinpath(dir, "pipeline.log"), "a") do io
            println(io, Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), "  ", msg)
        end
    end
    pipeline_log(project::ProjectCtx, msg::String) = pipeline_log(project.dir, msg)

    function log_written(dir::String, path::String)
        h = open(io -> bytes2hex(sha256(io)), path, "r")
        rel = "./" * relpath(path, dir)
        pipeline_log(dir, "Written: $rel  sha256:$h")
    end
    log_written(project::ProjectCtx, path::String) = log_written(project.dir, path)

    """
        reset_tool_logs(paths...)

    Truncate a stage's tool logs, creating their parent directory if absent.

    `Tools._run_logged` appends, so that a stage running several commands does not
    have each one destroy its predecessor's record. Truncation is therefore the
    stage's own responsibility, once at entry; without this call a re-run would
    accrete indefinitely onto the previous run's log.
    """
    function reset_tool_logs(paths::AbstractString...)
        for path in paths
            mkpath(dirname(path))
            open(io -> nothing, path, "w")
        end
        return nothing
    end

    ## Command capture
    # A tool's output records what it said, never what it was asked. The resolved
    # command line is the only witness to the latter, so it goes into the log
    # before the tool runs and survives even a crash. The marker is fixed so that
    # `grep '^\[MetaManifold\] cmd: '` recovers every command a run issued, across
    # the shell tools and the embedded R stages alike.
    const CMD_MARKER = "[MetaManifold]"

    """
        log_command(cmd_str, log_path)

    Append the resolved command line to `log_path` behind the fixed marker,
    before the tool runs. Both `Tools` (shell subprocesses) and the DADA2 remote
    Rscript invocation call this; the local R stages emit the same marker through
    their sink (see `DADA2._r_run_logged`).
    """
    function log_command(cmd_str::AbstractString, log_path::AbstractString)
        open(log_path, "a") do io
            println(io, CMD_MARKER, " command at ",
                    Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
            println(io, CMD_MARKER, " cmd: ", cmd_str)
        end
    end

    ## The log registry
    # (stage_label, relative_path) pairs; only existing files are included.
    # This is the single declarative record of every log, stats, and hash file the
    # pipeline writes. It is enforced, not merely documented: the drift guard in
    # test/unit/test_log.jl walks a populated run directory and fails the suite on
    # any file that appears neither here nor in _LOG_REGISTRY_EXCLUSIONS below. A
    # new log therefore cannot enter the pipeline unnoticed, as the SWARM branch
    # once did.
    const _TOOL_LOG_FILES = [
        ("QC",       "QC/logs/fastqc.log"),
        ("QC",       "QC/logs/multiqc.log"),
        ("QC",       "QC/config.hash"),
        ("cutadapt", "cutadapt/logs/cutadapt.log"),
        ("cutadapt", "cutadapt/logs/cutadapt_primer_trimming_stats.txt"),
        ("cutadapt", "cutadapt/logs/cutadapt_trimmed_percentage.txt"),
        ("cutadapt", "cutadapt/config.hash"),
        ("DADA2",    "dada2/Logs/prefilter_qc.log"),
        ("DADA2",    "dada2/Logs/filter_trim.log"),
        ("DADA2",    "dada2/Logs/learn_errors.log"),
        ("DADA2",    "dada2/Logs/denoise.log"),
        ("DADA2",    "dada2/Logs/filter_length.log"),
        ("DADA2",    "dada2/Logs/chimera_removal.log"),
        ("DADA2",    "dada2/Logs/assign_taxonomy.log"),
        ("DADA2",    "dada2/Checkpoints/prefilter_qc.hash"),
        ("DADA2",    "dada2/Checkpoints/filter_trim.hash"),
        ("DADA2",    "dada2/Checkpoints/learn_errors.hash"),
        ("DADA2",    "dada2/Checkpoints/denoise.hash"),
        ("DADA2",    "dada2/Checkpoints/filter_length.hash"),
        ("DADA2",    "dada2/Checkpoints/chimera_removal.hash"),
        ("DADA2",    "dada2/Checkpoints/assign_taxonomy.hash"),
        ("VSEARCH",  "vsearch/logs/vsearch.log"),
        ("VSEARCH",  "vsearch/config.hash"),
        ("cd-hit",   "cdhit/logs/cdhit.log"),
        ("cd-hit",   "cdhit/config.hash"),
        ("SWARM",    "swarm/logs/filter_ns.log"),
        ("SWARM",    "swarm/logs/swarm.log"),
        ("SWARM",    "swarm/logs/rename.log"),
        ("SWARM",    "swarm/config.hash"),
        ("SWARM",    "swarm/vsearch/logs/vsearch.log"),
        ("SWARM",    "swarm/vsearch/config.hash"),
        ("merge",    "merged/config.hash"),
        ("merge",    "merged/config_otu.hash"),
    ]

    ## Registry exclusions
    # Files the drift guard sees but which are deliberately kept out of the
    # consolidated log. Each carries its reason, so that excluding a file is an
    # act of judgement recorded in source rather than an omission nobody noticed.
    const _LOG_REGISTRY_EXCLUSIONS = [
        # Companion to each config.hash, listing the config keys the hash was taken
        # over. combined_pipeline.log already embeds run_config.yml verbatim, so
        # these carry nothing the consolidated record does not hold already.
        r"\.hash\.values$",
        # MultiQC's own working directory, written by MultiQC rather than by
        # MetaManifold, and superseded by the multiqc_report.html the run retains.
        r"^QC/multiqc_data/",
        # DADA2's R workspace images: binary resumption state, not a record of
        # anything, and far too large to append. The .hash file beside each one is
        # what attests to the checkpoint, and that is registered.
        r"^dada2/Checkpoints/.*\.RData$",
        # The consolidated record itself. Appending it to itself would recurse.
        r"^pipeline\.log$",
        r"^combined_pipeline\.log$",
        # A per-sample read-attrition data table, not a tool log: a first-class
        # analysis output carried by the run directory and surfaced in the UI.
        r"^dada2/Tables/pipeline_stats\.csv$",
    ]

    ## Drift guard support
    # The scan is deliberately broad. A narrow one would let a newly written log
    # slip past, which is precisely the failure this machinery exists to prevent,
    # so it errs towards sweeping in files that must then be judged explicitly.
    const _LOG_SCAN_RE =
        r"(\.log$)|(\.hash$)|(\.hash\.values$)|((^|/)(logs|Logs|Checkpoints)/)|(stats[^/]*\.(txt|csv)$)"

    """
        scan_log_files(dir) -> Vector{String}

    Every path under `dir`, relative and slash-separated, that looks like a log,
    a stats file, or a stage hash.
    """
    function scan_log_files(dir::String)::Vector{String}
        found = String[]
        for (root, _, files) in walkdir(dir)
            for f in files
                rel = replace(relpath(joinpath(root, f), dir), '\\' => '/')
                occursin(_LOG_SCAN_RE, rel) && push!(found, rel)
            end
        end
        return sort!(found)
    end

    log_registered(rel::AbstractString) = any(e -> e[2] == rel, _TOOL_LOG_FILES)
    log_excluded(rel::AbstractString)   = any(re -> occursin(re, rel), _LOG_REGISTRY_EXCLUSIONS)

    """
        unregistered_logs(dir) -> Vector{String}

    The log files under `dir` that the registry neither carries nor excludes.
    A non-empty result is registry drift and fails the test suite.
    """
    unregistered_logs(dir::String) =
        filter(rel -> !log_registered(rel) && !log_excluded(rel), scan_log_files(dir))

    const _TOOL_SECTION_OPEN  = "--- Tool logs appended below ---"
    const _TOOL_SECTION_CLOSE = "--- End of tool logs ---"

    # Drop any tool-log section a previous finalise_log left behind, keeping every
    # timestamped narrative line before it. Without this the section is appended
    # afresh on each re-run, and a run directory that has been re-run k times carries
    # k copies of every tool log (fastqc.log for a 300-sample run is not small).
    # The narrative IS a ledger and must accrete; the tool-log dump is a snapshot of
    # the current files and must not.
    function _strip_tool_section!(dir::String)
        path = joinpath(dir, "pipeline.log")
        isfile(path) || return nothing
        lines = readlines(path)
        cut = findfirst(l -> endswith(l, _TOOL_SECTION_OPEN), lines)
        isnothing(cut) && return nothing
        open(path, "w") do io
            for l in lines[1:cut-1]
                println(io, l)
            end
        end
        nothing
    end

    """
        finalise_log(project::ProjectCtx)

    Replace the tool-log section of the run's `pipeline.log` with the current
    contents of every registered tool-level log, stats, and hash file. Idempotent:
    call once per run after all stages complete, and again on every re-run.
    """
    function finalise_log(project::ProjectCtx)
        _strip_tool_section!(project.dir)
        pipeline_log(project, _TOOL_SECTION_OPEN)
        prev_stage = ""
        for (stage, relpath_) in _TOOL_LOG_FILES
            abspath_ = joinpath(project.dir, relpath_)
            isfile(abspath_) || continue
            if stage != prev_stage
                pipeline_log(project, "")  # blank separator
                prev_stage = stage
            end
            _append_tool_file(project.dir, relpath_, abspath_)
        end
        pipeline_log(project, _TOOL_SECTION_CLOSE)
    end

    function _append_tool_file(dir::String, relpath_::String, abspath_::String)
        contents = read(abspath_, String)
        open(joinpath(dir, "pipeline.log"), "a") do io
            println(io, ">>>>>> ", relpath_)
            print(io, contents)
            if !isempty(contents) && !endswith(contents, '\n')
                println(io)
            end
            println(io, "<<<<<< ", relpath_)
        end
    end

    """
        write_combined_log(projects; study_dir)

    Finalise each run's log (appending tool-level files), then write a
    combined log to `{study_dir}/combined_pipeline.log` that merges all
    per-run `pipeline.log` files, each run's `run_config.yml`, plus any
    group- and study-level logs.
    """
    function write_combined_log(projects::Vector{ProjectCtx};
                                study_dir::String = projects[1].study_dir)
        for project in projects
            finalise_log(project)
        end

        out_path = joinpath(study_dir, "combined_pipeline.log")
        sep = "=" ^ 72

        open(out_path, "w") do io
            println(io, sep)
            println(io, "  Combined pipeline log")
            println(io, "  Generated: ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
            println(io, "  Study: ", study_dir)
            println(io, "  Runs:  ", length(projects))
            println(io, sep)

            for project in projects
                run_name = relpath(project.dir, study_dir)
                println(io, "\n", sep)
                println(io, "  RUN: ", run_name)
                println(io, sep)

                config_path = joinpath(project.dir, "run_config.yml")
                if isfile(config_path)
                    println(io, "\n--- run_config.yml ---")
                    print(io, read(config_path, String))
                    println(io)
                end

                log_path = joinpath(project.dir, "pipeline.log")
                if isfile(log_path)
                    println(io, "--- pipeline.log ---")
                    print(io, read(log_path, String))
                end
            end

            # Directories between run dirs and study root
            group_dirs = Set{String}()
            for project in projects
                gdir = dirname(project.dir)
                while gdir != study_dir && startswith(gdir, study_dir)
                    push!(group_dirs, gdir)
                    gdir = dirname(gdir)
                end
            end

            for gdir in sort(collect(group_dirs))
                log_path = joinpath(gdir, "pipeline.log")
                isfile(log_path) || continue
                gname = relpath(gdir, study_dir)
                println(io, "\n", sep)
                println(io, "  GROUP: ", gname)
                println(io, sep)
                println(io, "\n--- pipeline.log ---")
                print(io, read(log_path, String))
            end

            study_log = joinpath(study_dir, "pipeline.log")
            if isfile(study_log)
                println(io, "\n", sep)
                println(io, "  STUDY")
                println(io, sep)
                println(io, "\n--- pipeline.log ---")
                print(io, read(study_log, String))
            end
        end

        @info "Written: $out_path"
        return out_path
    end
end
