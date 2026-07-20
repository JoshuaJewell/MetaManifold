module Validation

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export validate_environment, validate_project, ValidationError,
       DENOVO_METHODS, SAFE_NAME_RE, is_safe_name, primer_document_errors,
       database_document_errors

    using YAML, Logging
    using ..PipelineTypes
    using ..Config

    ## Safe names
    # The one guard for every user-supplied name that reaches a filesystem path or a
    # quoted SQL identifier: study, run, preset, filter, and category-set names.
    # It lived in nine places across four modules and had to be corrected in each by
    # hand, which is precisely how such a guard rots into an injection or traversal
    # hole. Note `\z`, not `$`: PCRE's `$` also matches before a trailing newline, so
    # `"evil\n"` satisfied the old spelling.
    const SAFE_NAME_RE = r"\A[A-Za-z0-9._-]+\z"

    is_safe_name(s::AbstractString) = occursin(SAFE_NAME_RE, s)

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

    # A section that is present but null is not the same as an absent one: `get`
    # returns the default only when the key is absent, so a null section reaches
    # the iteration as `nothing`. This function must never throw: it backs a write
    # gate where a throw is a bare 500 rather than an actionable 400.
    _seq(v) = v isa AbstractVector ? v : Any[]

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

    ## Database document rules
    # The single source of truth for the STRUCTURE of a databases document, shared
    # by the environment validator (_validate_databases) and
    # DatabasesLibrary.validate. Operates on the native document shape (a
    # databases: mapping of dir plus one entry per database). Returns
    # human-readable errors; empty means valid. Never throws: every section and
    # entry is type-checked before use.
    #
    # This is deliberately thin, and it holds structure only. Two other kinds of
    # rule deliberately live elsewhere:
    #
    # Rules that would fail a databases.yml which validates today (an empty levels
    # list, a misspelt vsearch_format) are WRITE-time rules and live in
    # DatabasesLibrary.validate.
    #
    # Rules about the ENVIRONMENT the document is read in, of which "a local: path
    # names a file that exists right now" is the only one, live in
    # _validate_databases below. A document is not invalid for naming a file that
    # has yet to arrive: the user may legitimately save the path first, and the
    # pipeline reports the absence when it goes looking. Keeping such a rule here
    # put it in the write gate, where one stale local: anywhere in the file
    # rejected every save of the whole document, and where the 400 disclosed to
    # any client whether an arbitrary path exists on the server.
    function database_document_errors(cfg::AbstractDict)::Vector{String}
        errors = String[]
        dbs = get(cfg, "databases", nothing)
        dbs isa AbstractDict ||
            push!(errors, "databases.yml missing 'databases:' key")
        errors
    end

    ## Database Validation
    # isfile does not merely answer the question: it throws on a NUL byte
    # (embedded NULs are not allowed in C strings) and on a path whose parent
    # directory cannot be read (EACCES). Both are reachable from a hand-edited
    # databases.yml, and a throw out of the environment validator is an
    # unexplained stack trace rather than a named error, so anything isfile cannot
    # answer is treated as not-a-file.
    function _is_named_file(p::AbstractString)
        occursin('\0', p) && return false
        try
            isfile(p)
        catch
            false
        end
    end

    # Whether each configured local: path names a file that exists. This is the
    # environment rule the validator exists to report: it says the config points
    # at something that is not there, which is true of the machine and not of the
    # document. It is deliberately not a write-time rule; see the note above.
    function _validate_database_files(errors::Vector{ValidationError}, ctx::String, cfg::AbstractDict)
        dbs = get(cfg, "databases", nothing)
        dbs isa AbstractDict || return
        for (db_name, db_cfg) in dbs
            # `dir` is the shared cache directory, not a database. It shares this
            # namespace with the entries, which is why no database may be called dir.
            string(db_name) == "dir" && continue
            db_cfg isa AbstractDict || continue
            for method in ("dada2", "vsearch")
                mc = get(db_cfg, method, nothing)
                mc isa AbstractDict || continue
                local_path = get(mc, "local", nothing)
                isnothing(local_path) && continue
                _is_named_file(string(local_path)) ||
                    _err(errors, ctx, "$db_name.$method.local: file not found: $local_path")
            end
        end
    end

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
        for msg in database_document_errors(cfg)
            _err(errors, ctx, msg)
        end
        _validate_database_files(errors, ctx, cfg)
    end

    ## Primer document rules
    # The single source of truth for what a valid primers document is, shared by
    # the environment validator (_validate_primers) and PrimersLibrary.validate.
    # Operates on the native document shape (Forward/Reverse maps, Pairs a list of
    # single-key mappings name => [fwd, rev]). Returns human-readable errors; empty
    # means valid. Never throws: every section and entry is type-checked before use.
    #
    # Primer and pair names are deliberately NOT charset-checked. They are only
    # ever lookup keys: get_primer_args resolves a pair name to its sequences, and
    # only the sequence (checked against the IUPAC set below) reaches the cutadapt
    # command. No name reaches a filesystem path, a shell, or a SQL identifier, so
    # a charset rule here would reject a primers.yml that the pipeline runs
    # perfectly well, and would buy nothing.
    function primer_document_errors(cfg::AbstractDict)::Vector{String}
        errors = String[]
        fwd = get(cfg, "Forward", Dict())
        rev = get(cfg, "Reverse", Dict())

        fwd isa AbstractDict || push!(errors, "'Forward' must be a mapping of name -> sequence")
        rev isa AbstractDict || push!(errors, "'Reverse' must be a mapping of name -> sequence")

        valid_bases = Set("ACGTMRWSYKVHDBNacgtmrwsykvhdbn")
        for (name, seq) in merge(fwd isa AbstractDict ? fwd : Dict(),
                                 rev isa AbstractDict ? rev : Dict())
            if !(seq isa AbstractString)
                push!(errors, "primer '$name' sequence is not a string")
                continue
            end
            bad = filter(c -> c ∉ valid_bases, seq)
            isempty(bad) ||
                push!(errors, "primer '$name' contains invalid bases: $(join(unique(bad)))")
        end

        pairs = get(cfg, "Pairs", [])
        pairs isa AbstractVector || return errors
        for entry in pairs
            entry isa AbstractDict || continue
            for (pair_name, members) in entry
                if !(members isa AbstractVector && length(members) == 2)
                    push!(errors, "pair '$pair_name' must list exactly [ForwardName, ReverseName]")
                    continue
                end
                f_name, r_name = string(members[1]), string(members[2])
                fwd isa AbstractDict && haskey(fwd, f_name) ||
                    push!(errors, "pair '$pair_name' references unknown forward primer '$f_name'")
                rev isa AbstractDict && haskey(rev, r_name) ||
                    push!(errors, "pair '$pair_name' references unknown reverse primer '$r_name'")
            end
        end
        errors
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
        for m in primer_document_errors(cfg)
            _err(errors, ctx, m)
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
