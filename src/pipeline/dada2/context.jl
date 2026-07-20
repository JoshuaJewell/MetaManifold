# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Shared pipeline context - helpers and setup called at the start of every stage.
# Included into module DADA2 by src/dada2.jl.

    ## Emitter
    # Returns a function that routes progress messages to @info (CLI) or a
    # Channel{String} (Genie SSE). Pass the result as `emit` in stage functions.
    _emitter(::Nothing,           lbl="") = msg -> @info (isempty(lbl) ? msg : "[$lbl] $msg")
    _emitter(ch::Channel{String}, lbl="") = msg -> put!(ch,  isempty(lbl) ? msg : "[$lbl] $msg")

    ## Database helpers
    # Resolve the DADA2 taxonomy database from config/databases.yml.
    function _resolve_taxonomy_db(cfg, emit)
        db_key   = string(cfg["taxonomy"]["database"])
        dbs_path = joinpath(@__DIR__, "..", "..", "..", "config", "databases.yml")
        isfile(dbs_path) ||
            error("config/databases.yml not found. Run new_project() first.")
        return resolve_db(dbs_path, db_key, "dada2"; emit)
    end

    ## Config
    function validate_config(cfg)
        required = ["file_patterns", "filter_trim", "dada",
                    "merge", "asv", "taxonomy", "output"]
        missing_secs = filter(k -> !haskey(cfg, k), required)
        isempty(missing_secs) ||
            error("Missing required config sections: $(join(missing_secs, ", "))")

        mode = get(cfg["file_patterns"], "mode", "paired")
        mode in ("paired", "forward", "reverse") ||
            error("file_patterns.mode must be one of: paired, forward, reverse")

        haskey(cfg["taxonomy"], "database") ||
            error("taxonomy.database is required")
    end

    ## File discovery
    function find_fastq_files(input_dir, fwd_pattern, rev_pattern, mode)
        all_files = sort(readdir(input_dir, join=true))
        fwd = mode in ("paired", "forward") ?
            filter(f -> !isnothing(match(Regex(fwd_pattern), basename(f))), all_files) : String[]
        rev = mode in ("paired", "reverse") ?
            filter(f -> !isnothing(match(Regex(rev_pattern), basename(f))), all_files) : String[]
        fwd, rev
    end

    function validate_sample_files(fwd, rev, mode)
        if mode in ("paired", "forward")
            isempty(fwd) &&
                error("No forward FASTQ files found. " *
                    "Check workspace.input_dir and file_patterns.forward.")
            for f in fwd
                isfile(f) || error("Forward file not found: $f")
            end
        end
        if mode in ("paired", "reverse")
            isempty(rev) &&
                error("No reverse FASTQ files found. " *
                    "Check workspace.input_dir and file_patterns.reverse.")
            for f in rev
                isfile(f) || error("Reverse file not found: $f")
            end
        end
        if mode == "paired" && length(fwd) != length(rev)
            error("Forward file count ($(length(fwd))) does not match " *
                "reverse file count ($(length(rev))).")
        end
    end

    function extract_sample_names(files)
        [replace(basename(f), r"_R[12]_trimmed\.fastq\.gz$" => "") for f in files]
    end

    # Workspace
    function setup_workspace(root)
        dirs = Dict(
            "Tables"      => joinpath(root, "Tables"),
            "Checkpoints" => joinpath(root, "Checkpoints"),
            "Figures"     => joinpath(root, "Figures"),
            "Filtered"    => joinpath(root, "Filtered"),
            "Logs"        => joinpath(root, "Logs"),
        )
        for d in values(dirs)
            mkpath(d)
        end
        dirs
    end

    ## R command provenance
    # Render a Julia value as R source text, so a command string assembled here
    # parses and evaluates in R exactly as written. This is what lets a single
    # string be both logged and run: the record cannot drift from what executed,
    # because there is only one string.
    _r_lit(x::Bool)           = x ? "TRUE" : "FALSE"
    _r_lit(x::Integer)        = string(x)
    _r_lit(x::Real)           = string(x)
    _r_lit(x::AbstractString) = '"' * replace(replace(x, "\\" => "\\\\"), "\"" => "\\\"") * '"'
    _r_lit(x::AbstractVector) = "c(" * join(_r_lit.(x), ", ") * ")"
    _r_lit(::Nothing)         = "NULL"

    # Emit the resolved R command behind the standard marker, then evaluate that
    # very string. Call only from within a stage's sink block: the marker `cat`
    # goes to the sinked connection, so R remains the sole writer to the log and
    # no second file handle can interleave. `grep '^\[MetaManifold\] cmd: '`
    # recovers these beside the shell tools' commands.
    function _r_run_logged(cmd::AbstractString)
        marker = PipelineLog.CMD_MARKER * " cmd: R> " * cmd * "\n"
        R"cat($marker)"
        reval(cmd)
    end

    ## R function loader
    # Source the R helper functions into the current R session. Called by each
    # stage after its mtime skip check, so R is not loaded for skipped stages.
    # When `ctx` is provided, emits the single-sample warning (once per run).
    const _single_sample_warned = Ref(false)
    function _source_r_functions(ctx=nothing)
        if !isnothing(ctx) && ctx.single_sample && !_single_sample_warned[]
            _single_sample_warned[] = true
            @warn "Only 1 sample found. Duplicating it to work around dada() " *
                  "returning a bare object for single-file input. The duplicate " *
                  "will be dropped from all outputs."
        end
        functions_r = joinpath(@__DIR__, "dada2_functions.r")
        R"source($functions_r)"
    end

    ## Pipeline context
    # Shared pure-Julia setup called at the start of every stage: loads and
    # validates config, discovers files, handles the single-sample fallback, and
    # computes all path variables. Returns a NamedTuple so stage functions can
    # extract what they need without repeating boilerplate.
    #
    # Optional overrides (used when main.jl manages directory layout):
    #   input_dir      - overrides cfg["workspace"]["input_dir"]
    #   workspace_root - overrides cfg["workspace"]["root"]
    function _pipeline_context(config_path::String; input_dir=nothing, workspace_root=nothing)
        full_cfg = YAML.load_file(config_path)
        cfg = get(full_cfg, "dada2", Dict{String,Any}())

        isnothing(input_dir)      && error("input_dir must be provided")
        isnothing(workspace_root) && error("workspace_root must be provided")
        isdir(input_dir)          || error("input_dir does not exist: $input_dir")

        validate_config(cfg)
        verbose = get(cfg, "verbose", true)
        seed    = Int(get(full_cfg, "seed", DEFAULT_SEED))
        mode    = get(cfg["file_patterns"], "mode", "paired")
        root    = workspace_root
        dirs    = setup_workspace(root)

        fwd_files, rev_files = find_fastq_files(
            input_dir,
            "_R1_trimmed.fastq.gz",
            "_R2_trimmed.fastq.gz",
            mode)
        validate_sample_files(fwd_files, rev_files, mode)

        primary_files = isempty(fwd_files) ? rev_files : fwd_files
        sample_names  = extract_sample_names(primary_files)

        # Single-sample fallback: dada() returns a bare object (not a list) for a
        # single input file, breaking makeSequenceTable() and sapply() downstream.
        # Duplicate the paths so the pipeline sees 2 samples; the extra row is
        # dropped in chimera_removal(). ASV calls are unaffected.
        single_sample = length(sample_names) == 1
        if single_sample
            fwd_files    = isempty(fwd_files) ? fwd_files : repeat(fwd_files, 2)
            rev_files    = isempty(rev_files) ? rev_files : repeat(rev_files, 2)
            sample_names = [sample_names[1], sample_names[1] * "_dup"]
        end

        filtered_dir = dirs["Filtered"]
        fwd_out = mode != "reverse" ?
            [joinpath(filtered_dir, s * "_R1_filt.fastq.gz") for s in sample_names] : String[]
        rev_out = mode != "forward" ?
            [joinpath(filtered_dir, s * "_R2_filt.fastq.gz") for s in sample_names] : String[]

        in_fwd      = mode != "reverse" ? fwd_files : rev_files
        out_fwd     = mode != "reverse" ? fwd_out   : rev_out
        in_rev_arg  = mode == "paired"  ? rev_files : nothing
        out_rev_arg = mode == "paired"  ? rev_out   : nothing

        ckpts = Dict(
            "filter"  => joinpath(dirs["Checkpoints"], "ckpt_filter.RData"),
            "errors"  => joinpath(dirs["Checkpoints"], "ckpt_errors.RData"),
            "denoise" => joinpath(dirs["Checkpoints"], "ckpt_denoise.RData"),
            "length"  => joinpath(dirs["Checkpoints"], "ckpt_length.RData"),
            "chimera" => joinpath(dirs["Checkpoints"], "ckpt_chimera.RData"),
        )

        # Run label for logging: last path component before /dada2
        run_label = basename(dirname(root))

        (; cfg, verbose, seed, mode, dirs, sample_names, single_sample,
        fwd_files, rev_files, fwd_out, rev_out,
        in_fwd, out_fwd, in_rev_arg, out_rev_arg, ckpts, run_label)
    end
