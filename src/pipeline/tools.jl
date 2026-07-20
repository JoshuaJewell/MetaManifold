module Tools

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export cutadapt, vsearch, multiqc, cdhit, tool_bin, _sq, _run_logged, _safe_optional_args

    using YAML
    using SHA
    using CSV
    using DataFrames
    using Logging
    using ..PipelineTypes
    using ..PipelineLog
    using ..Config

    _sq(s::AbstractString) = "'" * replace(s, "'" => "'\\''") * "'"

    # The resolved command line is logged before a tool runs via
    # PipelineLog.log_command, whose marker cd-hit's own volunteered command line
    # sits beside without collision. Appends, never truncates: a stage that issues
    # several commands must not have each one destroy its predecessor's record.
    # Truncation is the stage's own affair, done once at entry via reset_tool_logs.
    function _run_logged(cmd_str::String, log_path::String)
        mkpath(dirname(log_path))
        log_command(cmd_str, log_path)
        try
            open(log_path, "a") do io
                run(pipeline(`bash -lc $cmd_str`; stdout=io, stderr=io))
            end
        catch e
            isfile(log_path) && print(stderr, read(log_path, String))
            rethrow()
        end
    end

    ## Tools loading from config
    """
        load_tools(config_path) -> Dict{String,String}

    Read config/tools.yml and return a Dict of tool name => resolved path.
    If the file does not exist, returns an empty Dict so tools fall back to PATH.
    Paths with `@` are SSH remote paths (user@host:/path), the calling module is
    responsible for routing those calls via SSH.
    """
    function load_tools(config_path = joinpath(@__DIR__, "..", "..", "config", "tools.yml"))
        isfile(config_path) || return Dict{String,String}()
        data = YAML.load_file(config_path)
        tools = Dict{String,String}()
        for (name, info) in data
            path = info isa Dict ? get(info, "path", nothing) : nothing
            path !== nothing && (tools[name] = string(path))
        end
        tools
    end

    const _BIN_DEFAULTS = Dict("cd_hit_est" => "cd-hit-est")
    tool_bin(key) = get(_tools, key, get(_BIN_DEFAULTS, key, key))

    const _tools = load_tools()

    ## Argument sanitisation
    # optional_args are interpolated into shell commands; reject shell metacharacters.
    const _SAFE_ARGS_RE = r"^[A-Za-z0-9\s\-_\.=,/:+]+$"
    function _safe_optional_args(cfg::Dict, key::String="optional_args")::String
        raw = strip(get(cfg, key, ""))
        isempty(raw) && return ""
        occursin(_SAFE_ARGS_RE, raw) ||
            error("optional_args contains unsafe characters: $(repr(raw))")
        raw
    end

    ## Argument builders
    function _cutadapt_version(cutadapt_bin::AbstractString)
        try
            version = readchomp(`bash -lc $(cutadapt_bin * " --version")`)
            return VersionNumber(strip(split(version, '\n')[1]))
        catch
            return nothing
        end
    end

    function _cutadapt_supports_threads(cutadapt_bin::AbstractString)::Bool
        version = _cutadapt_version(cutadapt_bin)
        if isnothing(version)
            @warn "Cutadapt: could not determine version of '$cutadapt_bin'; disabling threaded mode."
            return false
        end
        return version >= v"1.15.0"
    end

    function _cutadapt_optional_args(cfg::Dict; cutadapt_bin = tool_bin("cutadapt"))::String
        parts = String[]
        min_len = get(cfg, "min_length", 200)
        push!(parts, "-m $min_len")
        get(cfg, "discard_untrimmed", true) && push!(parts, "--discard-untrimmed")
        cores = get(cfg, "cores", 0)
        if cores != 1
            if _cutadapt_supports_threads(cutadapt_bin)
                push!(parts, "-j $cores")   # -j 1 is default; 0 = auto
            else
                @warn "Cutadapt: '$cutadapt_bin' does not support -j; running single-threaded."
            end
        end
        quality_cutoff = get(cfg, "quality_cutoff", nothing)
        isnothing(quality_cutoff) || push!(parts, "-q $quality_cutoff")
        error_rate = get(cfg, "error_rate", nothing)
        isnothing(error_rate) || push!(parts, "-e $error_rate")
        overlap = get(cfg, "overlap", nothing)
        isnothing(overlap) || push!(parts, "-O $overlap")
        extra = _safe_optional_args(cfg)
        isempty(extra) || push!(parts, extra)
        join(parts, " ")
    end

    function _vsearch_args(cfg::Dict)::String
        parts = String[]
        push!(parts, "--id $(get(cfg, "identity", 0.75))")
        push!(parts, "--query_cov $(get(cfg, "query_cov", 0.8))")
        maxaccepts = get(cfg, "maxaccepts", nothing)
        isnothing(maxaccepts) || push!(parts, "--maxaccepts $maxaccepts")
        maxrejects = get(cfg, "maxrejects", nothing)
        isnothing(maxrejects) || push!(parts, "--maxrejects $maxrejects")
        strand = get(cfg, "strand", nothing)
        isnothing(strand) || push!(parts, "--strand $strand")
        extra = _safe_optional_args(cfg)
        isempty(extra) || push!(parts, extra)
        join(parts, " ")
    end

    function _cdhit_args(cfg::Dict)::String
        parts = String[]
        push!(parts, "-c $(get(cfg, "identity", 0.97))")
        threads = get(cfg, "threads", 0)
        push!(parts, "-T $threads")
        extra = _safe_optional_args(cfg)
        isempty(extra) || push!(parts, extra)
        join(parts, " ")
    end

    function get_primers(input, primers_path, seen_fwd::Vector{String}, seen_rev::Vector{String})
        data = YAML.load_file(primers_path)

        for pair in data["Pairs"]
            if haskey(pair, input)
                pair_names = pair[input]

                forward = data["Forward"][pair_names[1]]
                reverse = data["Reverse"][pair_names[2]]

                output_forward = in(forward, seen_fwd) ? "x" : forward
                output_reverse = in(reverse, seen_rev) ? "x" : reverse

                if output_forward != "x"
                    push!(seen_fwd, output_forward)
                end
                if output_reverse != "x"
                    push!(seen_rev, output_reverse)
                end

                return (output_forward, output_reverse)
            end
        end

        path = abspath(primers_path)
        error("Primer pair '$input' not found in '$path'. " *
              "Valid pairs: $(join(collect(only(keys(p)) for p in data["Pairs"]), ", "))")
    end

    function get_primer_args(primer_pairs, primers_path; mode="paired")
        seen_fwd = String[]
        seen_rev = String[]
        args = ""

        for pair in primer_pairs
            pair_tuple = get_primers(pair, primers_path, seen_fwd, seen_rev)
            forward_primer = pair_tuple[1]
            reverse_primer = pair_tuple[2]

            if mode == "paired"
                args *= join([flag * primer * " "
                              for (flag, primer) in (("-g ", forward_primer), ("-G ", reverse_primer))
                              if primer != "x"], "")
            elseif mode == "forward"
                # Trim only the forward primer from the 5' end of R1.
                forward_primer != "x" && (args *= "-g $forward_primer ")
            elseif mode == "reverse"
                # Trim only the reverse primer from the 5' end of the single read.
                reverse_primer != "x" && (args *= "-g $reverse_primer ")
            end
        end

        return rstrip(args)
    end

    function run_cutadapt(primer_args, optional_args, fastq_in_dir, cutadapt_dir,
                          cutadapt_bin; mode="paired", r1_suffix="_R1", r2_suffix="_R2")
        entries = [FastqEntry(joinpath(fastq_in_dir, f), f)
                   for f in readdir(fastq_in_dir) if endswith(f, ".fastq.gz")]
        run_cutadapt(primer_args, optional_args, entries, cutadapt_dir,
                     cutadapt_bin; mode, r1_suffix, r2_suffix)
    end

    function run_cutadapt(primer_args, optional_args, fastq_entries::Vector{FastqEntry},
                          cutadapt_dir, cutadapt_bin;
                          mode="paired", r1_suffix="_R1", r2_suffix="_R2")
        samples    = String[]
        r1_map     = Dict{String,String}()   # sample => absolute input path
        r2_map     = Dict{String,String}()
        out_prefix = Dict{String,String}()   # sample => output name prefix

        log_dir          = joinpath(cutadapt_dir, "logs")
        stats_path       = joinpath(log_dir, "cutadapt_primer_trimming_stats.txt")
        summary_path     = joinpath(log_dir, "cutadapt_trimmed_percentage.txt")
        cmd_log          = joinpath(log_dir, "cutadapt.log")
        stats_basename   = basename(stats_path)
        summary_basename = basename(summary_path)

        # Commands go to their own log rather than into the stats file: the summary
        # step greps the latter for "passing" and "filtered", and a command line
        # carrying either word in a path would misalign the columns it pastes.
        # The stage owns truncation, since every write below only appends.
        reset_tool_logs(stats_path, cmd_log)

        # Sample name = everything before the first occurrence of the R1/R2 suffix
        # in the *output-safe* name (which carries the sub-group prefix when pooled).
        primary_suffix  = (mode == "reverse") ? r2_suffix : r1_suffix
        primary_pattern = Regex(primary_suffix * raw"[^/]*\.fastq\.gz$")

        for entry in sort(fastq_entries, by = e -> e.name)
            occursin(primary_pattern, entry.name) || continue
            parts  = split(entry.name, primary_suffix; limit=2)
            sample = parts[1]
            rest   = parts[2]   # e.g. ".fastq.gz" or "_001.fastq.gz"
            if !(sample in samples)
                push!(samples, sample)
                out_prefix[sample] = sample
            end
            r1_map[sample] = entry.path
            # Build the R2 input path: same source directory, swap suffix in original filename.
            orig_dir  = dirname(entry.path)
            orig_base = basename(entry.path)
            r2_base   = replace(orig_base, primary_suffix => r2_suffix; count=1)
            r2_map[sample] = joinpath(orig_dir, r2_base)
        end

        @info("Cutadapt: Running in $mode mode with arguments: $primer_args $optional_args.")

        nsamples = length(samples)
        for (i, sample) in enumerate(samples)
            @info("Cutadapt: Sample $i/$nsamples ($sample).")
            pfx = out_prefix[sample]

            if mode == "paired"
                inputR1  = r1_map[sample]
                inputR2  = r2_map[sample]
                outputR1 = joinpath(cutadapt_dir, pfx * "_R1_trimmed.fastq.gz")
                outputR2 = joinpath(cutadapt_dir, pfx * "_R2_trimmed.fastq.gz")
                cutadapt_cmd = "$cutadapt_bin $primer_args $optional_args -o $(_sq(outputR1)) -p $(_sq(outputR2)) $(_sq(inputR1)) $(_sq(inputR2))"
            elseif mode == "forward"
                inputR1  = r1_map[sample]
                outputR1 = joinpath(cutadapt_dir, pfx * "_R1_trimmed.fastq.gz")
                cutadapt_cmd = "$cutadapt_bin $primer_args $optional_args -o $(_sq(outputR1)) $(_sq(inputR1))"
            else  # reverse
                inputR2  = r2_map[sample]
                outputR2 = joinpath(cutadapt_dir, pfx * "_R2_trimmed.fastq.gz")
                cutadapt_cmd = "$cutadapt_bin $primer_args $optional_args -o $(_sq(outputR2)) $(_sq(inputR2))"
            end

            log_command(cutadapt_cmd, cmd_log)
            try
                open(stats_path, "a") do io
                    run(pipeline(`bash -lc $cutadapt_cmd`; stdout=io, stderr=io))
                end
            catch e
                log_tail = isfile(stats_path) ? read(stats_path, String) : ""
                error("cutadapt failed for sample '$sample':\n$log_tail\n$(sprint(showerror, e))")
            end
        end

        samples_str = join((_sq(s) for s in samples), " ")
        cmd = "paste <(printf \"%s\\n\" $samples_str) " *
            "<(grep \"passing\" $(_sq(stats_basename)) | cut -f3 -d \"(\" | tr -d \")\") " *
            "<(grep \"filtered\" $(_sq(stats_basename)) | cut -f3 -d \"(\" | tr -d \")\") " *
            "> $(_sq(summary_basename))"

        log_command(cmd, cmd_log)
        cd(log_dir) do
            run(pipeline(`bash -lc $cmd`))
        end

        @info("Cutadapt: Complete. Output available in $cutadapt_dir.")
        return cutadapt_dir
    end

    """
        cutadapt(primer_pairs, primers_path, fastq_in_dir, cutadapt_dir; optional_args, cutadapt_bin)

    Requires `cutadapt` installed. Runs `cutadapt` with as many primer pairs as necessary
    (useful for multiplex) and any optional parameters. Primer arguments are determined from YAML file in format:
    ``` YAML
        Forward:
            PrimerF: "CCAGCASCYGCGGTAATTCC"

        Reverse:
            Primer1R: "ACTTTCGTTCTTGATYRA"
            Primer2R: "DCTKTCGTYCTTGATYRA"

        Pairs:
            - PrimerPair1:
                - PrimerF
                - Primer1R
            - PrimerPair2:
                - PrimerF
                - Primer2R
    ```
    Where a primer pair contains the same forward or reverse as another specified pair, these are deduplicated by name rather than sequence. For example:
    ```julia
    primer_pairs = ["PrimerPair1", "PrimerPair2"]
    ```
    This would execute `cutadapt` with arguments `-g CCAGCASCYGCGGTAATTCC -G ACTTTCGTTCTTGATYRA -G DCTKTCGTYCTTGATYRA`.

    ## Arguments
    - `primer_pairs`: Specify primers in string array format.
    - `primers_path`: Specify path of YAML file for primers.
    - `fastq_in_dir`: Specify path of *_*_L001_R1_001.fastq.gz and *_*_L001_R2_001.fastq.gz files for cutadapt.
    - `cutadapt_dir`: Specify an output directory for trimmed .fastq.gz and logs.

    ## Keyword Arguments
    - `optional_args` (optional, default: "-m 200 --discard-untrimmed"): Specify additional arguments passed to `cutadapt` command.
    - `cutadapt_bin` (optional, default: "cutadapt"): Path to the cutadapt binary. Defaults to PATH lookup. Set via `config/tools.yml` and `load_tools()` in main.jl.

    """
    function cutadapt(
        primer_pairs,
        primers_path,
        fastq_in_dir,
        cutadapt_dir;
        optional_args = "-m 200 --discard-untrimmed",
        cutadapt_bin  = tool_bin("cutadapt")
    )
        if isdir(cutadapt_dir)
            trimmed = filter(f -> endswith(f, "_trimmed.fastq.gz"), readdir(cutadapt_dir))
            if !isempty(trimmed) &&
               all(f -> mtime(joinpath(cutadapt_dir, f)) > mtime(primers_path), trimmed)
                @info "Cutadapt: Skipping - trimmed reads up to date in $cutadapt_dir"
                return TrimmedReads(cutadapt_dir)
            end
        end
        run_cutadapt(
            get_primer_args(primer_pairs, primers_path),
            optional_args,
            fastq_in_dir,
            cutadapt_dir,
            cutadapt_bin
        )
        return TrimmedReads(cutadapt_dir)
    end

    # Number of trimmed FASTQs cutadapt should have produced for `entries`.
    # run_cutadapt keys off primary-read files only (one sample per R1, or per R2
    # in reverse mode); paired mode then writes two trimmed files per sample, the
    # single-end modes one. `entries` may be primary-only (subsampled path) or the
    # full raw set (R1 + R2), so the count must be taken over primary reads rather
    # than the raw length, else paired runs expect double and never skip.
    function _expected_trimmed_count(entries, mode::AbstractString,
                                     primary_pattern::Regex)::Int
        n_primary = count(e -> occursin(primary_pattern, e.name), entries)
        mode == "paired" ? 2 * n_primary : n_primary
    end

    function cutadapt(project::ProjectCtx;
                      cutadapt_bin = tool_bin("cutadapt"))
        lbl          = basename(project.dir)
        config_path  = write_run_config(project)
        primers_path = joinpath(project.config_dir, "primers.yml")
        full_cfg     = YAML.load_file(config_path)
        cfg          = get(full_cfg, "cutadapt", Dict())
        fp_cfg       = get(get(full_cfg, "dada2", Dict()), "file_patterns", Dict())
        mode         = get(fp_cfg, "mode", "paired")
        r1_suffix    = get(cfg, "r1_suffix", "_R1")
        r2_suffix    = get(cfg, "r2_suffix", "_R2")
        primer_pairs = cfg["primer_pairs"]
        built_args   = _cutadapt_optional_args(cfg; cutadapt_bin)
        cutadapt_dir = joinpath(project.dir, "cutadapt")
        hash_file    = joinpath(cutadapt_dir, "config.hash")

        # Collect mtimes of all inputs: primers config + raw FASTQs.
        raw_entries   = find_fastqs(project)
        subsample_n   = Int(get(full_cfg, "subsample_n", 0))
        seed          = Int(get(full_cfg, "seed", DEFAULT_SEED))

        primary_suffix  = mode == "reverse" ? r2_suffix : r1_suffix
        primary_pattern = Regex(primary_suffix * raw"[^/]*\.fastq\.gz$")
        selected_entries = raw_entries
        if subsample_n > 0
            primary_entries = [e for e in raw_entries if occursin(primary_pattern, e.name)]
            if length(primary_entries) > subsample_n
                ranked_entries = sort(primary_entries;
                                      by = e -> bytes2hex(sha256("$(seed):$(e.name)")))
                selected_entries = sort(ranked_entries[1:subsample_n], by = e -> e.name)
                @info "[$lbl] Cutadapt: Subsampling $(length(selected_entries)) samples with seed=$seed"
            else
                selected_entries = sort(primary_entries, by = e -> e.name)
            end
        end

        raw_mtimes = if mode == "paired"
            sample_mtimes = Float64[]
            for entry in selected_entries
                push!(sample_mtimes, mtime(entry.path))
                mate_base = replace(basename(entry.path), r1_suffix => r2_suffix; count=1)
                mate_path = joinpath(dirname(entry.path), mate_base)
                isfile(mate_path) && push!(sample_mtimes, mtime(mate_path))
            end
            sample_mtimes
        else
            [mtime(e.path) for e in selected_entries]
        end
        primers_mtime = mtime(primers_path)
        input_mtime   = isempty(raw_mtimes) ? primers_mtime : max(primers_mtime, maximum(raw_mtimes))

        expected_trimmed = _expected_trimmed_count(selected_entries, mode, primary_pattern)
        if isdir(cutadapt_dir)
            trimmed = filter(f -> endswith(f, "_trimmed.fastq.gz"), readdir(cutadapt_dir))
            if !isempty(trimmed) &&
               length(trimmed) == expected_trimmed &&
               !_section_stale(config_path, stage_sections(:cutadapt), hash_file) &&
               all(f -> mtime(joinpath(cutadapt_dir, f)) > input_mtime, trimmed) &&
               all(f -> filesize(joinpath(cutadapt_dir, f)) > 20, trimmed)
                @info "[$lbl] Cutadapt: Skipping - trimmed reads up to date in $cutadapt_dir"
                return TrimmedReads(cutadapt_dir)
            end
        end

        if isdir(cutadapt_dir)
            for f in readdir(cutadapt_dir)
                path = joinpath(cutadapt_dir, f)
                if endswith(f, "_trimmed.fastq.gz") || f == "logs" || f == "config.hash" || f == "config.hash.values"
                    rm(path; recursive=true, force=true)
                end
            end
        end
        mkpath(cutadapt_dir)
        run_cutadapt(get_primer_args(primer_pairs, primers_path; mode), built_args,
                     selected_entries, cutadapt_dir, cutadapt_bin; mode, r1_suffix, r2_suffix)
        _write_section_hash(config_path, stage_sections(:cutadapt), hash_file)
        pipeline_log(project, "cutadapt complete")
        return TrimmedReads(cutadapt_dir)
    end

    ## FastQC / MultiQC
    """
        multiqc(fastq_in_dir, qc_dir; fastqc_args, multiqc_args, fastqc_bin, multiqc_bin)

    Run FastQC on all FASTQ files in `fastq_in_dir`, saving individual reports to
    `qc_dir/fastqc/`, then aggregate them into a MultiQC summary report at `qc_dir/`.

    ## Arguments
    - `fastq_in_dir`: Directory containing `.fastq` or `.fastq.gz` files.
    - `qc_dir`: Parent output directory. FastQC reports go to `qc_dir/fastqc/`;
      the MultiQC summary report goes to `qc_dir/`.

    ## Keyword Arguments
    - `fastqc_args` (optional, default: `"-t 20 --extract --delete"`): Additional arguments passed to `fastqc`.
    - `multiqc_args` (optional, default: `""`): Additional arguments passed to `multiqc`.
    - `fastqc_bin` (optional): Path to the fastqc binary. Set via `config/tools.yml`.
    - `multiqc_bin` (optional): Path to the multiqc binary. Set via `config/tools.yml`.
    """
    # Accept a single directory (backwards-compatible).
    function multiqc(fastq_in_dir::AbstractString, qc_dir; kwargs...)
        multiqc([fastq_in_dir], qc_dir; kwargs...)
    end

    function multiqc(fastq_in_dirs::Vector{<:AbstractString}, qc_dir;
                     fastqc_args  = "-t 20 --extract --delete",
                     multiqc_args = "",
                     fastqc_bin   = tool_bin("fastqc"),
                     multiqc_bin  = tool_bin("multiqc"),
                     force        = false)
        report = joinpath(qc_dir, "multiqc_report.html")
        if !force && isfile(report)
            all_fresh = true
            for d in fastq_in_dirs
                fastqs = filter(f -> occursin(r"\.fastq(\.gz)?$", f), readdir(d))
                if isempty(fastqs) || !all(f -> mtime(report) > mtime(joinpath(d, f)), fastqs)
                    all_fresh = false; break
                end
            end
            if all_fresh
                @info "MultiQC: Skipping - $report up to date"
                return
            end
        end

        fastqc_dir = joinpath(qc_dir, "fastqc")
        log_dir    = joinpath(qc_dir, "logs")
        mkpath(fastqc_dir)
        mkpath(log_dir)

        fastqc_log  = joinpath(log_dir, "fastqc.log")
        multiqc_log = joinpath(log_dir, "multiqc.log")
        # FastQC is invoked once per FASTQ and appends throughout; the stage clears
        # both logs here so that a re-run starts clean without any single command
        # clobbering the record of the one before it.
        reset_tool_logs(fastqc_log, multiqc_log)

        # Collect absolute paths from all input directories.
        all_fastqs = String[]
        for d in fastq_in_dirs
            for f in readdir(d)
                occursin(r"\.fastq(\.gz)?$", f) && push!(all_fastqs, joinpath(d, f))
            end
        end
        sort!(all_fastqs)

        nfiles = length(all_fastqs)
        if iszero(nfiles)
            @warn "FastQC: no FASTQ files found in $(join(fastq_in_dirs, ", "))"
            return
        end
        @info "FastQC: Processing $nfiles file$(nfiles == 1 ? "" : "s") across $(length(fastq_in_dirs)) dir(s)"
        for (i, fpath) in enumerate(all_fastqs)
            @info "FastQC: File $i/$nfiles - $(basename(fpath))"
            fqc_cmd = "$fastqc_bin $(_sq(fpath)) -o $(_sq(fastqc_dir)) $fastqc_args"
            _run_logged(fqc_cmd, fastqc_log)
        end
        @info "FastQC: Complete. Output: $fastqc_dir  Log: $fastqc_log"

        @info "MultiQC: Aggregating $nfiles report$(nfiles == 1 ? "" : "s") in $fastqc_dir"
        mqc_cmd = "$multiqc_bin $(_sq(fastqc_dir)) -o $(_sq(qc_dir)) $multiqc_args"
        _run_logged(mqc_cmd, multiqc_log)
        @info "MultiQC: Complete. Output: $qc_dir  Log: $multiqc_log"
    end

    function multiqc(project::ProjectCtx;
                     fastqc_bin  = tool_bin("fastqc"),
                     multiqc_bin = tool_bin("multiqc"))
        lbl          = basename(project.dir)
        config_path  = write_run_config(project)
        cfg          = YAML.load_file(config_path)
        fqc_cfg      = get(cfg, "fastqc",  Dict())
        mqc_cfg      = get(cfg, "multiqc", Dict())
        threads      = get(fqc_cfg, "threads", 20)
        fastqc_args  = "-t $threads --extract --delete"
        extra_fqc    = _safe_optional_args(fqc_cfg)
        isempty(extra_fqc) || (fastqc_args *= " $extra_fqc")
        multiqc_args = _safe_optional_args(mqc_cfg)
        qc_dir       = joinpath(project.dir, "QC")
        hash_file    = joinpath(qc_dir, "config.hash")
        report       = joinpath(qc_dir, "multiqc_report.html")

        # Skip if report exists, config unchanged, and report newer than all raw FASTQs.
        if isfile(report) && !_section_stale(config_path, stage_sections(:fastqc_multiqc), hash_file)
            raw_entries = find_fastqs(project)
            if !isempty(raw_entries) && all(e -> mtime(report) > mtime(e.path), raw_entries)
                @info "[$lbl] MultiQC: Skipping - $report up to date"
                return
            end
        end

        # Pass force=true so the lower-level mtime guard doesn't override this decision.
        # When pooling children, run FastQC across all data_dirs.
        multiqc(project.data_dirs, qc_dir;
                fastqc_args, multiqc_args, fastqc_bin, multiqc_bin, force=true)
        _write_section_hash(config_path, stage_sections(:fastqc_multiqc), hash_file)
        pipeline_log(project, "FastQC/MultiQC complete")
    end

    ## vsearch
    """
        vsearch(fasta_in_dir, reference_database; optional_args = "--id 0.75 --query_cov 0.8", vsearch_bin = "vsearch")

    Requires `vsearch` installed. Runs `vsearch` command with any optional parameters to perform taxonomy assignment by local alignment against specified database.

    ## Arguments
    - `fasta_in_dir`: Specify path of fasta files output by DADA2 pipeline.
    - `reference_database` (default: "./databases"): Specify path of reference database.

    ## Keyword Arguments
    - `optional_args` (optional, default: "--id 0.75 --query_cov 0.8"): Specify additional arguments passed to `vsearch` command.
    - `vsearch_bin` (optional, default: "vsearch"): Path to the vsearch binary. Defaults to PATH lookup. Set via `config/tools.yml` and `load_tools()` in main.jl.

    """
    function vsearch(fasta_in_dir, reference_database, vsearch_dir; optional_args = "--id 0.75 --query_cov 0.8", vsearch_bin = tool_bin("vsearch"))
        log_dir  = joinpath(vsearch_dir, "logs")
        mkpath(vsearch_dir)
        mkpath(log_dir)
        outfile  = joinpath(vsearch_dir, "taxonomy.tsv")
        log_path = joinpath(log_dir, "vsearch.log")
        reset_tool_logs(log_path)
        @info "VSEARCH: Running $fasta_in_dir against $(basename(reference_database))"
        # --userout with query+target+id captures the full FASTA header (including
        # description after the space), unlike --blast6out which truncates at the first space.
        cmd = "$vsearch_bin --usearch_global $(_sq(fasta_in_dir)) --db $(_sq(reference_database)) --userout $(_sq(outfile)) --userfields query+target+id $optional_args"
        _run_logged(cmd, log_path)
        @info "VSEARCH: Complete. Output: $outfile  Log: $log_path"
    end

    function vsearch(input::HasFasta, reference_database::String, vsearch_dir::String;
                     optional_args = "--id 0.75 --query_cov 0.8",
                     vsearch_bin   = tool_bin("vsearch"))
        tsv = joinpath(vsearch_dir, "taxonomy.tsv")
        if isfile(tsv) && mtime(tsv) > mtime(input.fasta)
            @info "VSEARCH: Skipping - $tsv up to date"
            return TaxonomyHits(tsv)
        end
        vsearch(input.fasta, reference_database, vsearch_dir;
                optional_args, vsearch_bin)
        return TaxonomyHits(tsv)
    end

    # Output directory depends on whether input is ASV or OTU sequences.
    _vsearch_outdir(project::ProjectCtx, ::ASVResult)  = joinpath(project.dir, "vsearch")
    _vsearch_outdir(project::ProjectCtx, ::OTUResult)  = joinpath(project.dir, "swarm", "vsearch")

    function vsearch(project::ProjectCtx, input::HasFasta, reference_database::String;
                     vsearch_bin = tool_bin("vsearch"))
        lbl         = basename(project.dir)
        config_path = write_run_config(project)
        cfg         = get(YAML.load_file(config_path), "vsearch", Dict())
        built_args  = _vsearch_args(cfg)
        vsearch_dir = _vsearch_outdir(project, input)
        tsv         = joinpath(vsearch_dir, "taxonomy.tsv")
        hash_file   = joinpath(vsearch_dir, "config.hash")
        if isfile(tsv) &&
           !_section_stale(config_path, stage_sections(:vsearch), hash_file) &&
           mtime(tsv) > mtime(input.fasta)
            @info "[$lbl] VSEARCH: Skipping - $tsv up to date"
            return TaxonomyHits(tsv)
        end
        vsearch(input.fasta, reference_database, vsearch_dir; optional_args=built_args, vsearch_bin)
        _write_section_hash(config_path, stage_sections(:vsearch), hash_file)
        pipeline_log(project, "VSEARCH: $(input.fasta) against $(basename(reference_database))")
        log_written(project, tsv)
        return TaxonomyHits(tsv)
    end

    ## cd-hit-est
    """
        _parse_cdhit_clstr(clstr_path) -> Dict{String,String}

    Parse a cd-hit `.clstr` file into a mapping of `member_id => representative_id`.
    The representative in each cluster is the entry marked with `*`.
    """
    function _flush_cluster!(rep_map, cluster_seqs, rep)
        isempty(cluster_seqs) && return
        rep_local = something(rep, cluster_seqs[1])
        for s in cluster_seqs
            rep_map[s] = rep_local
        end
    end

    function _parse_cdhit_clstr(clstr_path::String)::Dict{String,String}
        rep_map = Dict{String,String}()
        cluster_seqs = String[]
        rep = nothing
        pat = r">(.*?)\.\.\."

        for line in eachline(clstr_path)
            if startswith(line, ">Cluster")
                _flush_cluster!(rep_map, cluster_seqs, rep)
                cluster_seqs = String[]
                rep = nothing
                continue
            end
            m = match(pat, line)
            isnothing(m) && continue
            sid = strip(m.captures[1])
            push!(cluster_seqs, sid)
            if occursin('*', line)
                rep = sid
            end
        end
        _flush_cluster!(rep_map, cluster_seqs, rep)
        return rep_map
    end

    """
        _collapse_cdhit_counts(clstr_path, count_table_path, out_path) -> String

    Read the cd-hit `.clstr` file and the DADA2 count table, sum sample counts
    for ASVs that belong to the same cluster, and write the collapsed table to
    `out_path`. Returns `out_path`.
    """
    function _first_nonmissing(col)
        for v in skipmissing(col)
            return v
        end
        return nothing
    end

    function _collapse_cdhit_counts(clstr_path::String, count_table_path::String,
                                     out_path::String)::String
        rep_map = _parse_cdhit_clstr(clstr_path)
        df = copy(CSV.read(count_table_path, DataFrame))

        id_col = names(df)[1]

        df[!, :_Representative] = [get(rep_map, strip(string(v)), strip(string(v)))
                                    for v in df[!, id_col]]

        # Classify columns by first non-missing value type
        sample_cols = String[]
        text_cols = String[]
        for col in names(df)
            col in (id_col, "_Representative") && continue
            v = _first_nonmissing(df[!, col])
            if !isnothing(v) && v isa Number
                push!(sample_cols, col)
            else
                push!(text_cols, col)
            end
        end

        # Sum sample counts by representative
        gdf = groupby(df, :_Representative)
        collapsed = combine(gdf, [Symbol(c) => sum => Symbol(c) for c in sample_cols]...)
        rename!(collapsed, :_Representative => id_col)

        # Restore text metadata (e.g. sequence column) from the representative's own row
        if !isempty(text_cols)
            rep_meta = df[df[!, id_col] .== df[!, :_Representative],
                          vcat([id_col], text_cols)]
            unique!(rep_meta, id_col)
            collapsed = leftjoin(collapsed, rep_meta, on=id_col)
            collapsed = select(collapsed, id_col, text_cols..., sample_cols...)
        end

        CSV.write(out_path, collapsed)
        @info "CD-HIT: Collapsed $(nrow(df)) ASVs -> $(nrow(collapsed)) representatives in $out_path"
        return out_path
    end

    """
        cdhit(fasta_in, cdhit_dir; optional_args = "-c 0.9", cdhit_bin)

    Run cd-hit-est on a FASTA file, writing the clustered output to `cdhit_dir`.
    Returns the path to the output FASTA.

    ## Arguments
    - `fasta_in`: Path to the input FASTA file.
    - `cdhit_dir`: Output directory for the clustered FASTA and `.clstr` file.

    ## Keyword Arguments
    - `optional_args` (optional, default: `"-c 0.9"`): Additional arguments passed to `cd-hit-est`.
    - `cdhit_bin` (optional): Path to the cd-hit-est binary. Set via `config/tools.yml`.
    """
    function cdhit(fasta_in, cdhit_dir; optional_args = "-c 0.9", cdhit_bin = tool_bin("cd_hit_est"))
        log_dir  = joinpath(cdhit_dir, "logs")
        mkpath(cdhit_dir)
        mkpath(log_dir)
        fasta_out = joinpath(cdhit_dir, basename(fasta_in))
        log_path  = joinpath(log_dir, "cdhit.log")
        reset_tool_logs(log_path)
        @info "CD-HIT: Running on $fasta_in"
        cmd = "$cdhit_bin -i $(_sq(fasta_in)) -o $(_sq(fasta_out)) $optional_args"
        _run_logged(cmd, log_path)
        @info "CD-HIT: Complete. Output: $fasta_out  Log: $log_path"
        return fasta_out
    end

    function cdhit(input::ASVResult, cdhit_dir::String;
                   optional_args = "-c 0.9",
                   cdhit_bin     = tool_bin("cd_hit_est"))
        new_fasta = joinpath(cdhit_dir, basename(input.fasta))
        collapsed_counts = joinpath(cdhit_dir, "collapsed_counts.csv")
        if isfile(new_fasta) && isfile(collapsed_counts) &&
           mtime(new_fasta) > mtime(input.fasta)
            @info "CD-HIT: Skipping - $new_fasta up to date"
            return ASVResult(new_fasta, collapsed_counts, input.taxonomy)
        end
        new_fasta = cdhit(input.fasta, cdhit_dir; optional_args, cdhit_bin)
        clstr_path = new_fasta * ".clstr"
        _collapse_cdhit_counts(clstr_path, input.count_table, collapsed_counts)
        return ASVResult(new_fasta, collapsed_counts, input.taxonomy)
    end

    function cdhit(project::ProjectCtx, input::ASVResult;
                   cdhit_bin = tool_bin("cd_hit_est"))
        lbl         = basename(project.dir)
        config_path = write_run_config(project)
        cfg         = get(YAML.load_file(config_path), "cdhit", Dict())
        built_args  = _cdhit_args(cfg)
        cdhit_dir   = joinpath(project.dir, "cdhit")
        new_fasta   = joinpath(cdhit_dir, basename(input.fasta))
        collapsed_counts = joinpath(cdhit_dir, "collapsed_counts.csv")
        hash_file   = joinpath(cdhit_dir, "config.hash")
        if isfile(new_fasta) && isfile(collapsed_counts) &&
           !_section_stale(config_path, stage_sections(:cdhit), hash_file) &&
           mtime(new_fasta) > mtime(input.fasta)
            @info "[$lbl] CD-HIT: Skipping - $new_fasta up to date"
            return ASVResult(new_fasta, collapsed_counts, input.taxonomy)
        end
        new_fasta = cdhit(input.fasta, cdhit_dir; optional_args=built_args, cdhit_bin)
        clstr_path = new_fasta * ".clstr"
        _collapse_cdhit_counts(clstr_path, input.count_table, collapsed_counts)
        _write_section_hash(config_path, stage_sections(:cdhit), hash_file)
        pipeline_log(project, "cd-hit-est complete")
        log_written(project, new_fasta)
        return ASVResult(new_fasta, collapsed_counts, input.taxonomy)
    end
end
