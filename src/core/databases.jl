module Databases

# Ensures all databases declared in the config are available locally,
# downloading from their configured URIs as needed.
#
# Usage:
#   dbs = ensure_databases("config/databases.yml")
#   dbs["pr2_dada2"]   # -> resolved local path for DADA2 assignTaxonomy
#   dbs["pr2_vsearch"] # -> resolved local path for VSEARCH --db
#
# Keys follow the pattern  "<database_name>_<format>",  e.g. "pr2_dada2",
# "pr2_vsearch".  Format names map to the sub-keys under each database entry
# in the databases: config section.
#
# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

import Downloads
using YAML, Logging
using ..PipelineTypes

export ensure_databases, resolve_db, make_db_meta

    """
        ensure_databases(config_path) -> Dict{String,String}

    Reads the `databases:` section of `config_path`, ensures every declared
    database file is present in `databases.dir` (downloading from `uri` if the
    file is absent), and returns a Dict mapping `"<name>_<format>"` keys to
    resolved absolute local paths.

    Set a `local:` path under any entry to use a pre-existing file directly.
    If the `local:` path does not exist, the function warns and falls back to
    downloading from `uri`.
    """
    function ensure_databases(config_path::String)
        if !isfile(config_path)
            template_path = joinpath(dirname(config_path), "defaults", "databases.yml")
            if isfile(template_path)
                cp(template_path, config_path)
                @warn "ensure_databases: $config_path not found - copied from $template_path. " *
                    "Set local: paths for any pre-downloaded databases."
            else
                @warn "ensure_databases: $config_path not found. " *
                    "Copy config/defaults/databases.yml to config/databases.yml and set local: paths."
                return Dict{String,String}()
            end
        end

        cfg    = YAML.load_file(config_path)
        db_cfg = get(cfg, "databases", nothing)

        if isnothing(db_cfg) || isempty(db_cfg)
            @warn "ensure_databases: no `databases:` section found in $config_path"
            return Dict{String,String}()
        end

        db_dir = abspath(get(db_cfg, "dir", "./databases"))
        mkpath(db_dir)

        resolved = Dict{String,String}()
        for (db_name, db_info) in db_cfg
            db_name == "dir" && continue
            !(db_info isa AbstractDict) && continue
            for (fmt, fmt_info) in db_info
                !(fmt_info isa AbstractDict) && continue
                # Skip entries where both uri and local are null/missing.
                uri_val   = get(fmt_info, "uri", nothing)
                local_val = get(fmt_info, "local", nothing)
                if isnothing(uri_val) && isnothing(local_val)
                    continue
                end
                key = "$(db_name)_$(fmt)"
                resolved[key] = _resolve_entry(key, fmt_info, db_dir)
            end
        end
        return resolved
    end

    """
        resolve_db(config_path, db_name, fmt; emit=nothing) -> String

    Resolve a single database entry from a databases.yml file.

    `config_path` is the path to a databases.yml-style config, `db_name` is the
    key under `databases:` (e.g., `"pr2"`), and `fmt` is the format sub-key
    (e.g., `"dada2"` or `"vsearch"`). Returns the resolved absolute local path.

    Pass an `emit` function (e.g., from `_emitter`) to route log messages through
    the pipeline's progress channel instead of the default `@info` logger.
    """
    function resolve_db(config_path::String, db_name::String, fmt::String; emit=nothing)
        cfg    = YAML.load_file(config_path)
        db_cfg = get(cfg, "databases", Dict())
        db_dir = abspath(get(db_cfg, "dir", "./databases"))
        mkpath(db_dir)

        haskey(db_cfg, db_name) ||
            error("Database '$db_name' not found in $config_path")
        fmt_cfg = get(db_cfg[db_name], fmt, nothing)
        isnothing(fmt_cfg) &&
            error("databases.$db_name.$fmt is not configured in $config_path")

        _resolve_entry("$(db_name)_$(fmt)", fmt_cfg, db_dir; emit)
    end

    # Fixed column names that are never sample counts, regardless of database.
    const _FIXED_NONCOUNTS = Set([
        "SeqName", "ASV", "ASVs", "OTU",
        "Pident", "Accession", "rRNA", "Organellum", "specimen",
        "Sequence", "sequence", "", "Column1",
    ])

    """
        make_db_meta(config_path, db_name) -> DatabaseMeta

    Construct a `DatabaseMeta` from the database entry in `config_path`.
    Pre-computes `noncounts` as the union of taxonomy levels (including
    `_dada2` suffixed variants) and fixed metadata column names.
    """
    function make_db_meta(config_path::String, db_name::String)
        cfg    = YAML.load_file(config_path)
        db_cfg = get(cfg, "databases", Dict())
        haskey(db_cfg, db_name) ||
            error("Database '$db_name' not found in $config_path")
        entry = db_cfg[db_name]

        levels     = String[string(l) for l in get(entry, "levels", String[])]
        vsformat   = string(get(entry, "vsearch_format", "generic"))
        raw_corr   = get(entry, "corrections", [])
        corrections = Dict{String,Any}[]
        if raw_corr isa Vector
            for c in raw_corr
                c isa AbstractDict && push!(corrections, Dict{String,Any}(string(k) => v for (k,v) in c))
            end
        end

        noncounts = copy(_FIXED_NONCOUNTS)
        for l in levels
            push!(noncounts, l)
            push!(noncounts, l * "_dada2")
            push!(noncounts, l * "_vsearch")
            push!(noncounts, l * "_boot")
        end

        return DatabaseMeta(db_name, levels, vsformat, corrections, noncounts)
    end

    function _resolve_entry(key, fmt_info, db_dir; emit=nothing)
        log = isnothing(emit) ? msg -> @info(msg) : emit
        local_p = get(fmt_info, "local", nothing)
        if !isnothing(local_p)
            local_p = string(local_p)
            if !isempty(local_p)
                if isfile(local_p)
                    log("[$key] Using local file: $local_p")
                    return local_p
                end
                @warn "[$key] Configured local path not found: $local_p - falling back to uri"
            end
        end

        uri = get(fmt_info, "uri", nothing)
        isnothing(uri) &&
            error("databases entry '$key': no valid local path and no uri is configured")

        cached = joinpath(db_dir, basename(uri))
        if isfile(cached)
            log("[$key] Using cached: $cached")
        else
            log("[$key] Downloading: $uri")
            Downloads.download(uri, cached)
            log("[$key] Saved to: $cached")
        end

        return cached
    end

end