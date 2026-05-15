module Validation

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export validate_environment, validate_project, ValidationError,
       DENOVO_METHODS

    using YAML, Logging
    using ..PipelineTypes
    using ..Config

    # Allowed chimera detection methods accepted by DADA2's removeBimeraDenovo.
    # Kept here so configuration validation and the call-site guard in
    # pipeline/dada2/chimera.jl share a single source of truth.
    const DENOVO_METHODS = ("consensus", "pooled", "per-sample")

    struct ValidationError
        context::String
        message::String
    end

    function _err(errors::Vector{ValidationError}, ctx::String, msg::String)
        push!(errors, ValidationError(ctx, msg))
    end

    _is_number(val) = val isa Number && !isnan(Float64(val))

    # IUPAC ambiguity codes -> regex character classes
    const _IUPAC = Dict(
        'M' => "[AC]", 'R' => "[AG]", 'W' => "[AT]", 'S' => "[CG]",
        'Y' => "[CT]", 'K' => "[GT]", 'V' => "[ACG]", 'H' => "[ACT]",
        'D' => "[AGT]", 'B' => "[CGT]", 'N' => "[ACGT]",
    )
    function _primer_regex(seq::String)
        buf = IOBuffer()
        for c in uppercase(seq)
            write(buf, get(_IUPAC, c, string(c)))
        end
        Regex(String(take!(buf)))
    end

    ## Tools Validation
    function _validate_tools(errors::Vector{ValidationError}, tools_config_path::String)
        ctx = "tools"
        isfile(tools_config_path) || begin
            _err(errors, ctx, "tools.yml not found at $tools_config_path - run install.jl first")
            return
        end
        cfg = YAML.load_file(tools_config_path)
        cfg isa Dict || begin
            _err(errors, ctx, "tools.yml is not a valid YAML mapping")
            return
        end

        required = ["cutadapt", "fastqc", "multiqc", "vsearch", "cd_hit_est"]
        for key in required
            entry = get(cfg, key, nothing)
            path  = entry isa Dict ? get(entry, "path", nothing) : entry
            if isnothing(path)
                _err(errors, ctx, "$key: not configured in tools.yml")
                continue
            end
            resolved = isfile(string(path)) ? string(path) : Sys.which(string(path))
            if isnothing(resolved)
                _err(errors, ctx, "$key: path '$path' not found or not executable")
            end
        end
    end

    ## Database Validation
    function _validate_databases(errors::Vector{ValidationError}, databases_config_path::String)
        ctx = "databases"
        isfile(databases_config_path) || begin
            _err(errors, ctx, "databases.yml not found at $databases_config_path")
            return
        end
        cfg = YAML.load_file(databases_config_path)
        cfg isa Dict || begin
            _err(errors, ctx, "databases.yml is not a valid YAML mapping")
            return
        end
        dbs = get(cfg, "databases", nothing)
        dbs isa Dict || begin
            _err(errors, ctx, "databases.yml missing 'databases:' key")
            return
        end
        for (db_name, db_cfg) in dbs
            db_name == "dir" && continue
            db_cfg isa Dict || continue
            for method in ("dada2", "vsearch")
                mc = get(db_cfg, method, nothing)
                mc isa Dict || continue
                local_path = get(mc, "local", nothing)
                isnothing(local_path) && continue
                isfile(string(local_path)) ||
                    _err(errors, ctx, "$db_name.$method.local: file not found: $local_path")
            end
        end
    end

    ## Primers Validation
    function _validate_primers(errors::Vector{ValidationError}, primers_path::String)
        ctx = "primers ($primers_path)"
        isfile(primers_path) || begin
            _err(errors, ctx, "primers.yml not found")
            return
        end
        cfg = YAML.load_file(primers_path)
        cfg isa Dict || begin
            _err(errors, ctx, "not a valid YAML mapping")
            return
        end
        fwd   = get(cfg, "Forward", Dict())
        rev   = get(cfg, "Reverse", Dict())
        pairs = get(cfg, "Pairs",   [])

        fwd isa Dict || _err(errors, ctx, "'Forward' must be a mapping of name -> sequence")
        rev isa Dict || _err(errors, ctx, "'Reverse' must be a mapping of name -> sequence")

        valid_bases = Set("ACGTMRWSYKVHDBNacgtmrwsykvhdbn")
        for (name, seq) in merge(fwd isa Dict ? fwd : Dict(), rev isa Dict ? rev : Dict())
            seq isa String || begin
                _err(errors, ctx, "primer '$name' sequence is not a string"); continue
            end
            bad = filter(c -> c ∉ valid_bases, seq)
            isempty(bad) ||
                _err(errors, ctx, "primer '$name' contains invalid bases: $(join(unique(bad)))")
        end

        pairs isa Vector || return
        for entry in pairs
            entry isa Dict || continue
            for (pair_name, members) in entry
                members isa Vector && length(members) == 2 || begin
                    _err(errors, ctx, "pair '$pair_name' must list exactly [ForwardName, ReverseName]")
                    continue
                end
                f_name, r_name = string(members[1]), string(members[2])
                fwd isa Dict && haskey(fwd, f_name) ||
                    _err(errors, ctx, "pair '$pair_name' references unknown forward primer '$f_name'")
                rev isa Dict && haskey(rev, r_name) ||
                    _err(errors, ctx, "pair '$pair_name' references unknown reverse primer '$r_name'")
            end
        end
    end

    ## Pipeline Config Validation
    function _validate_pipeline_cfg(errors::Vector{ValidationError}, cfg::Dict, ctx::String)
        ca = get(cfg, "cutadapt", Dict())
        if ca isa Dict
            pp = get(ca, "primer_pairs", nothing)
            pp isa Vector && !isempty(pp) ||
                _err(errors, ctx, "cutadapt.primer_pairs must be a non-empty list")
            ml = get(ca, "min_length", nothing)
            (_is_number(ml) && ml > 0) ||
                _err(errors, ctx, "cutadapt.min_length must be a positive number (got: $ml)")
        end

        da = get(cfg, "dada2", Dict())
        if da isa Dict
            ft = get(da, "filter_trim", Dict())
            if ft isa Dict
                tl = get(ft, "trunc_len", nothing)
                ml = get(ft, "min_len",   nothing)
                if tl isa Vector && length(tl) >= 1 && _is_number(tl[1]) && _is_number(ml)
                    tl[1] > ml ||
                        _err(errors, ctx, "dada2.filter_trim.trunc_len[1] ($(tl[1])) must be > min_len ($ml)")
                end
                ee = get(ft, "max_ee", nothing)
                if ee isa Vector
                    all(x -> _is_number(x) && x >= 0, ee) ||
                        _err(errors, ctx, "dada2.filter_trim.max_ee values must be non-negative numbers")
                end
            end

            tx = get(da, "taxonomy", Dict())
            if tx isa Dict
                db = get(tx, "database", nothing)
                isnothing(db) || db isa String ||
                    _err(errors, ctx, "dada2.taxonomy.database must be a string")
                mb = get(tx, "multithread", nothing)
                # Accept either a Bool (DADA2's TRUE/FALSE meaning "all cores" /
                # "single thread") or a strict positive Integer. Reject floats
                # and strings explicitly so YAML's `true`, `4`, and `"4"` do not
                # silently flip code paths in the R wrapper.
                isnothing(mb) ||
                    (mb isa Bool) ||
                    (mb isa Integer && mb >= 1) ||
                    _err(errors, ctx,
                         "dada2.taxonomy.multithread must be a Bool or positive integer (got: $(repr(mb)))")
            end
        end

        asv = get(cfg, "asv", Dict())
        if asv isa Dict
            dm = get(asv, "denovo_method", nothing)
            isnothing(dm) || (dm isa AbstractString && dm in DENOVO_METHODS) ||
                _err(errors, ctx,
                     "asv.denovo_method must be one of $(join(DENOVO_METHODS, ", ")) (got: $(repr(dm)))")
        end

        vs = get(cfg, "vsearch", Dict())
        if vs isa Dict
            id = get(vs, "identity", nothing)
            isnothing(id) || (_is_number(id) && 0 < id <= 1) ||
                _err(errors, ctx, "vsearch.identity must be between 0 and 1 (got: $id)")
            qc = get(vs, "query_cov", nothing)
            isnothing(qc) || (_is_number(qc) && 0 < qc <= 1) ||
                _err(errors, ctx, "vsearch.query_cov must be between 0 and 1 (got: $qc)")
        end

        cd = get(cfg, "cdhit", Dict())
        if cd isa Dict
            id = get(cd, "identity", nothing)
            isnothing(id) || (_is_number(id) && 0 < id <= 1) ||
                _err(errors, ctx, "cdhit.identity must be between 0 and 1 (got: $id)")
        end

        sw = get(cfg, "swarm", Dict())
        if sw isa Dict
            d = get(sw, "differences", nothing)
            isnothing(d) || (_is_number(d) && d >= 0) ||
                _err(errors, ctx, "swarm.differences must be a non-negative integer (got: $d)")
            id = get(sw, "identity", nothing)
            isnothing(id) || (_is_number(id) && 0 < id <= 1) ||
                _err(errors, ctx, "swarm.identity must be between 0 and 1 (got: $id)")
        end
    end

    ## Per-project Validation
    """
        validate_project(project, databases_config_path) -> Vector{ValidationError}

    Validate a single project: data files present, config coherent, primer pairs defined.
    """
    function validate_project(project::ProjectCtx,
                               databases_config_path::String)::Vector{ValidationError}
        errors = ValidationError[]
        ctx    = basename(project.dir)

        for d in project.data_dirs
            isdir(d) ||
                _err(errors, ctx, "data directory not found: $d")
        end
        fastqs = find_fastqs(project)
        isempty(fastqs) &&
            _err(errors, ctx, "no .fastq.gz files found in $(join(project.data_dirs, ", "))")

        primers_path = joinpath(project.config_dir, "primers.yml")
        _validate_primers(errors, primers_path)

        try
            config_path = write_run_config(project)
            cfg         = YAML.load_file(config_path)
            _validate_pipeline_cfg(errors, cfg, ctx)

            # Check cutadapt primer_pairs references exist in primers.yml
            ca = get(cfg, "cutadapt", Dict())
            pp = get(ca,  "primer_pairs", String[])
            if pp isa Vector && isfile(primers_path)
                pcfg  = YAML.load_file(primers_path)
                pairs = get(pcfg, "Pairs", [])
                defined_pairs = Set{String}()
                for entry in (pairs isa Vector ? pairs : [])
                    entry isa Dict && union!(defined_pairs, string.(keys(entry)))
                end
                for name in pp
                    string(name) in defined_pairs ||
                        _err(errors, ctx, "cutadapt.primer_pairs references '$name' which is not defined in primers.yml")
                end
            end

            da      = get(cfg, "dada2",    Dict())
            tx      = get(da,  "taxonomy", Dict())
            db_name = string(get(tx, "database", "pr2"))
            db_cfg  = YAML.load_file(databases_config_path)
            dbs     = get(db_cfg isa Dict ? db_cfg : Dict(), "databases", Dict())
            haskey(dbs isa Dict ? dbs : Dict(), db_name) ||
                _err(errors, ctx, "dada2.taxonomy.database '$db_name' not found in databases.yml")
        catch e
            _err(errors, ctx, "could not load merged config: $e")
        end

        return errors
    end

    ## Entry Point
    """
        validate_environment(projects, databases_config_path, tools_config_path)

    Validate tools, databases, and all projects. Logs all errors and returns
    the total count. Caller should abort if count > 0.
    """
    function validate_environment(projects::Vector{ProjectCtx},
                                   databases_config_path::String,
                                   tools_config_path::String)::Int
        all_errors = ValidationError[]

        _validate_tools(all_errors, tools_config_path)
        _validate_databases(all_errors, databases_config_path)

        for project in projects
            append!(all_errors, validate_project(project, databases_config_path))
        end

        if isempty(all_errors)
            @info "Validation: all checks passed"
            return 0
        end

        @error "Validation failed with $(length(all_errors)) error(s):"
        for e in all_errors
            @error "  [$(e.context)] $(e.message)"
        end
        return length(all_errors)
    end

end
