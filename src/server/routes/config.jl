# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/studies/{study}/config
#         /api/v1/studies/{study}/runs/{run}/config
using JSON3, YAML
using MetaManifold.PrimersLibrary

const _config_file_lock = ReentrantLock()

## Config resolution
function _load_yml(path::String)
    isfile(path) ? something(YAML.load_file(path), Dict()) : Dict()
end

# Write a YAML document over `path` atomically. The temp file and rename mean a
# reader never observes a half-written file; the lock means two writes cannot
# interleave their bytes. It does NOT make a read-modify-write sequence atomic:
# two concurrent saves can still each validate against their own snapshot and
# the later one silently revert the earlier.
function _atomic_write_yaml(path::String, doc)
    mkpath(dirname(path))
    lock(_config_file_lock) do
        tmp = path * ".tmp"
        open(tmp, "w") do io
            YAML.write(io, doc)
        end
        mv(tmp, path; force=true)
    end
    nothing
end

## Recursively convert JSON3 values into plain Dict/Vector/scalars for YAML.write.
_to_plain(x::JSON3.Object) = Dict{String,Any}(string(k) => _to_plain(v) for (k, v) in x)
_to_plain(x::JSON3.Array)  = Any[_to_plain(v) for v in x]
_to_plain(x) = x

function _flatten(d::Dict, prefix::String="")
    out = Dict{String,Any}()
    for (k, v) in d
        key = prefix == "" ? string(k) : "$(prefix).$(k)"
        if v isa Dict
            merge!(out, _flatten(v, key))
        else
            out[key] = v
        end
    end
    out
end

function _default_cfg(root::String)
    factory = _flatten(_load_yml(joinpath(root, "config", "defaults", "pipeline.yml")))
    global_ = _flatten(_load_yml(joinpath(root, "config", "pipeline.yml")))
    merge(factory, global_)  # global overrides factory; factory provides all keys
end

# Returns the merged config cascade for a run as a flat dict of dotted keys,
# each annotated with its effective value and source level.
#
# Cascade order (lowest wins): default -> study -> group -> run
#
# "source" is the deepest level that explicitly sets the key.
# Keys not set at any user level have source "default".
function _resolve_config(study::String, run::Union{String,Nothing}=nothing,
                         group::Union{String,Nothing}=nothing)
    root        = dirname(ServerState.data_dir())
    default_cfg = _default_cfg(root)
    study_cfg   = _flatten(_load_yml(joinpath(ServerState.data_dir(), study, "pipeline.yml")))
    group_cfg   = isnothing(group) ? Dict{String,Any}() :
                  _flatten(_load_yml(joinpath(ServerState.data_dir(), study, group, "pipeline.yml")))
    run_cfg     = isnothing(run) ? Dict{String,Any}() :
                  _flatten(_load_yml(joinpath(ServerState.data_dir(), study,
                                              isnothing(group) ? run : joinpath(group, run),
                                              "pipeline.yml")))

    all_keys = union(keys(default_cfg), keys(study_cfg), keys(group_cfg), keys(run_cfg))

    Dict(k => begin
        if haskey(run_cfg, k)
            (; value=run_cfg[k],   source="run")
        elseif haskey(group_cfg, k)
            (; value=group_cfg[k], source="group")
        elseif haskey(study_cfg, k)
            (; value=study_cfg[k], source="study")
        elseif haskey(default_cfg, k)
            (; value=default_cfg[k], source="default")
        end
    end for k in all_keys)
end

## Per-study chart cosmetics (layout + name-keyed trace style), in pipeline.yml.
const _CHART_TYPES = Set(["taxa_bar", "alpha_richness", "alpha_shannon", "alpha_simpson",
                          "nmds", "composition_comparison", "pipeline_stats"])

function _resolve_chart_cosmetics(study::String, chart_type::String)
    cfg = _load_yml(joinpath(ServerState.data_dir(), study, "pipeline.yml"))
    all = get(cfg, "chart_cosmetics", nothing)
    all isa Dict || return Dict{String,Any}()
    entry = get(all, chart_type, nothing)
    entry isa Dict ? entry : Dict{String,Any}()
end

@get "/api/v1/studies/{study}/chart-cosmetics" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")
    cosmetics = get(_load_yml(joinpath(ServerState.data_dir(), study, "pipeline.yml")), "chart_cosmetics", Dict())
    json(cosmetics isa Dict ? cosmetics : Dict())
end

@patch "/api/v1/studies/{study}/chart-cosmetics" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")
    body = JSON3.read(String(req.body))
    chart_type = string(get(body, :chart_type, ""))
    chart_type in _CHART_TYPES || return json_error(400, "invalid_chart_type",
        "Unknown chart type '$chart_type'")
    clear = Bool(get(body, :clear, false))
    layout = get(body, :layout, nothing)
    traces = get(body, :traces, nothing)
    path = joinpath(ServerState.data_dir(), study, "pipeline.yml")
    lock(_config_file_lock) do
        cfg = _load_yml(path)
        cosmetics = get(cfg, "chart_cosmetics", nothing)
        cosmetics = cosmetics isa Dict ? cosmetics : Dict{Any,Any}()
        if clear
            delete!(cosmetics, chart_type)
        else
            entry = Dict{String,Any}()
            isnothing(layout) || (entry["layout"] = _to_plain(layout))
            isnothing(traces) || (entry["traces"] = _to_plain(traces))
            cosmetics[chart_type] = entry
        end
        isempty(cosmetics) ? delete!(cfg, "chart_cosmetics") : (cfg["chart_cosmetics"] = cosmetics)
        _atomic_write_yaml(path, cfg)
    end
    cosmetics2 = get(_load_yml(path), "chart_cosmetics", Dict())
    json(cosmetics2 isa Dict ? cosmetics2 : Dict())
end

## Allowed config keys - derived from defaults/pipeline.yml at load time.
# Only keys present in the factory defaults can be set via the API.
const _ALLOWED_CONFIG_KEYS = let
    factory_path = joinpath(@__DIR__, "..", "..", "..", "config", "defaults", "pipeline.yml")
    isfile(factory_path) ? Set(keys(_flatten(_load_yml(factory_path)))) : Set{String}()
end

function _validate_config_key(dotted_key::String)
    dotted_key in _ALLOWED_CONFIG_KEYS || error(
        "Config key '$dotted_key' is not a recognised pipeline option")
end

function _write_override(path::String, dotted_key::String, value)
    _validate_config_key(dotted_key)
    lock(_config_file_lock) do
        cfg = _load_yml(path)
        parts = split(dotted_key, ".")
        d = cfg
        for p in parts[1:end-1]
            child = get(d, p, nothing)
            if child isa Dict
                d = child
            elseif isnothing(child)
                new_dict = Dict()
                d[p] = new_dict
                d = new_dict
            else
                error("Config key segment '$p' is not a section; cannot set sub-key")
            end
        end
        d[parts[end]] = value
        _atomic_write_yaml(path, cfg)
    end
end

function _delete_override(path::String, dotted_key::String)
    isfile(path) || return
    lock(_config_file_lock) do
        cfg   = _load_yml(path)
        parts = split(dotted_key, ".")
        d     = cfg
        for p in parts[1:end-1]
            haskey(d, p) || return
            d = d[p]
            d isa Dict || return
        end
        delete!(d, parts[end])
        _atomic_write_yaml(path, cfg)
    end
end

## Routes
# Default (global) config endpoints
@get "/api/v1/config" function(req)
    root = dirname(ServerState.data_dir())
    json(Dict(k => (; value=v, source="default") for (k, v) in _default_cfg(root)))
end

@patch "/api/v1/config" function(req)
    root      = dirname(ServerState.data_dir())
    user_path = joinpath(root, "config", "pipeline.yml")
    body = JSON3.read(req.body)
    for (k, _) in body
        string(k) in _ALLOWED_CONFIG_KEYS || return json_error(400, "invalid_config_key",
            "Config key '$(string(k))' is not a recognised pipeline option")
    end
    for (k, v) in body
        _write_override(user_path, string(k), v)
    end
    json(Dict(k => (; value=v, source="default") for (k, v) in _default_cfg(root)))
end

@delete "/api/v1/config/{key}" function(req, key::String)
    root      = dirname(ServerState.data_dir())
    user_path = joinpath(root, "config", "pipeline.yml")
    _delete_override(user_path, key)
    json(Dict(k => (; value=v, source="default") for (k, v) in _default_cfg(root)))
end

# List available primer pair names from config/primers.yml
@get "/api/v1/primers" function(req)
    primers_path = joinpath(dirname(ServerState.data_dir()), "config", "primers.yml")
    isfile(primers_path) || return json([])
    cfg = YAML.load_file(primers_path)
    cfg isa Dict || return json([])
    pairs = get(cfg, "Pairs", [])
    pairs isa Vector || return json([])
    # Each pair is a single-key Dict like Dict("EMP" => ["EMP515F", "EMP806R"])
    names = String[]
    for p in pairs
        p isa Dict || continue
        for k in keys(p)
            push!(names, string(k))
        end
    end
    json(names)
end

## Primers document (whole-file view and edit)
_primers_path() = joinpath(dirname(ServerState.data_dir()), "config", "primers.yml")

# Atomic write of a document already in the native file shape. The temp file and
# rename mean a reader never observes a half-written file, and the lock means two
# concurrent writes cannot interleave their bytes into a corrupt file. It does
# NOT make read-validate-write atomic: two clients can each read the document
# before either writes, and the later write silently overwrites the earlier
# client's edit (a lost update, not a torn file).
function _write_primers(native::AbstractDict)
    _atomic_write_yaml(_primers_path(), native)
end

# Validate then write. Returns the saved canonical document, or an HTTP.Response
# error. The single gate every primers write passes through, so a dangling pair
# is caught here rather than surfacing as a run-time validation failure.
# The native shape is converted once and handed to both the gate and the write.
function _save_primers(doc::AbstractDict)
    native = PrimersLibrary.to_yaml_doc(doc)
    errors = PrimersLibrary.validate(doc; native)
    isempty(errors) || return json_error(400, "invalid_primers", join(errors, "; "))
    _write_primers(native)
    @info "Saved primers document ($(_primers_path()))"
    doc
end

# Read the document, turning an unparseable file into a 400 that names it
# rather than a 500. PrimersLibrary.load deliberately raises instead of
# degrading to an empty document, because an empty document would breeze
# through validation and the next Save would overwrite the real primers with
# nothing. Returns the document, or an HTTP.Response error.
function _read_primers()
    try
        PrimersLibrary.load(_primers_path())
    catch e
        @error "primers.yml is not readable" path=_primers_path() exception=(e, catch_backtrace())
        json_error(400, "primers_unreadable",
            "config/primers.yml cannot be read as a primers document and must be repaired by hand: $(sprint(showerror, e))")
    end
end

## Cascade-resolved config references
# Read a pipeline.yml for the reference scan. A file anywhere in the tree may be
# malformed, or may not be a mapping at all. Neither is a save's business: the
# scan gathers advisory warnings only, so an unreadable file is skipped with a
# warning rather than propagating. Letting it throw would make one stray file
# block EVERY save with a 500, the exact opposite of "warn, not block".
# Results are cached per call: an ancestor's pipeline.yml is on the cascade of
# every project beneath it and would otherwise be re-read once per descendant.
function _scan_yml(path::String, cache::Dict{String,Any})
    get!(cache, path) do
        cfg = try
            _load_yml(path)
        catch e
            @warn "Skipping an unreadable pipeline.yml while scanning for config references" path exception=e
            return Dict()
        end
        cfg isa AbstractDict ? cfg : Dict()
    end
end

# Sentinel for "this level does not set the key", distinct from a level that
# sets it to null. Only an absent key inherits: an explicit null overrides to
# null, which is what _resolve_config and Config.load_merged_config both do.
struct _Absent end
const _ABSENT = _Absent()

# The value at a dotted path, or _ABSENT when any segment is absent or is not a
# mapping. Distinguishing absent from present-and-null matters: only an absent
# key inherits, so _ABSENT (not nothing) is the sentinel for "this level does
# not set it"; a level that explicitly nulls the key returns nothing, which is
# a real value that overrides whatever an ancestor set.
function _getin(cfg, parts::Vector{String})
    cur = cfg
    for p in parts
        cur isa AbstractDict || return _ABSENT
        haskey(cur, p) || return _ABSENT
        cur = cur[p]
    end
    cur
end

# The names a resolved value contributes. A list key (cutadapt.primer_pairs)
# contributes each element; a scalar key (dada2.taxonomy.database) contributes
# itself. A level that is absent, or a value that is neither a list nor a
# scalar (a mapping, say), contributes no names. One scan therefore serves both.
_ref_names(v::AbstractVector) = String[string(x) for x in v]
_ref_names(::Nothing)         = String[]
_ref_names(::_Absent)         = String[]
_ref_names(::AbstractDict)    = String[]
_ref_names(v)                 = String[string(v)]

# Which projects effectively see each value of `dotted_key`, resolved through the
# real cascade: factory defaults, then the global config, then each ancestor
# pipeline.yml down to the project itself. Deepest wins. Returns
# value -> sorted project labels.
#
# Scanning raw files and reporting which ones NAME a value is wrong wherever the
# key has a factory default, because a project inherits the default without
# naming it anywhere. config/defaults/pipeline.yml sets both
# cutadapt.primer_pairs ("EMP") and dada2.taxonomy.database ("pr2"): on the real
# data tree three studies inherit the former and every project inherits the
# latter, so a name-scan reports nothing while the edit breaks all of them.
#
# The set of projects scanned is the union of every directory that owns a
# pipeline.yml and every run directory the pipeline route itself would submit
# (study/run and study/group/run, per _run_names/_group_names/_group_run_names).
# A run with no pipeline.yml of its own still inherits the factory default and
# would break identically, so it must be scanned too; a bare study or group
# directory that is not itself a run target and sets nothing of its own is not
# something that runs, so it is not forced in.
#
# Labels are project paths only. Neither the global config nor the factory
# defaults is a project, so neither is ever a label; they participate only as the
# base of each project's cascade.
function _cascade_refs(dotted_key::String)
    parts     = String[String(p) for p in split(dotted_key, ".")]
    root      = dirname(ServerState.data_dir())
    data_root = ServerState.data_dir()
    cache     = Dict{String,Any}()
    base = _getin(_scan_yml(joinpath(root, "config", "defaults", "pipeline.yml"), cache), parts)
    glob = _getin(_scan_yml(joinpath(root, "config", "pipeline.yml"), cache), parts)
    base_eff = glob isa _Absent ? base : glob
    refs = Dict{String,Vector{String}}()
    isdir(data_root) || return refs

    targets = Set{String}()
    # `onerror`, because walkdir defaults to onerror=throw and readdir raises
    # EACCES on a directory the server may not read. One 0700 directory under
    # data/, which a shared academic server acquires readily, then threw out of
    # here and made a 500 of EVERY databases save: _database_warnings calls this
    # unconditionally. Every other hazard in this function is already guarded
    # (_scan_yml catches, the _run_names loop catches per study); this was the
    # one that bypassed them. An unreadable directory is skipped, exactly as an
    # unreadable file is: these are advisory warnings, so a directory that
    # cannot be scanned costs a warning, never the write.
    for (dir, _, files) in walkdir(data_root; onerror = _ -> nothing)
        "pipeline.yml" in files || continue
        rel = relpath(dir, data_root)
        rel == "." || push!(targets, rel)
    end
    # Guarded per study: _run_names/_group_names/_group_run_names read pipeline.yml
    # unguarded (via _is_pooled) to detect a pooled run, so one malformed file
    # anywhere under a study can throw. Catching per study, rather than around
    # the whole loop, means one bad study is skipped with a warning while every
    # other study still enumerates correctly; the directories that own a
    # pipeline.yml are enumerated regardless, via the guarded walk above.
    for study in _study_names()
        try
            for r in _run_names(study)
                push!(targets, joinpath(study, r))
            end
            for g in _group_names(study)
                for r in _group_run_names(study, g)
                    push!(targets, joinpath(study, g, r))
                end
            end
        catch e
            @warn "Skipping run/group enumeration for a study while scanning for config references" study exception=e
        end
    end

    for rel in targets
        segs = splitpath(rel)
        eff  = base_eff
        for i in 1:length(segs)
            v = _getin(_scan_yml(joinpath(data_root, segs[1:i]..., "pipeline.yml"), cache), parts)
            v isa _Absent || (eff = v)
        end
        for name in _ref_names(eff)
            push!(get!(refs, name, String[]), rel)
        end
    end
    for k in keys(refs)
        refs[k] = sort(unique(refs[k]))
    end
    refs
end

# Pairs present in `current` (the document as it stands on disk) but absent from
# the submitted `doc`, that some project's config cascade still resolves to. A
# rename reads as the old name disappearing, so this covers both deletion and
# rename. The write is not blocked; these are warnings only.
#
# `current` is passed in rather than re-read here. The handler has already loaded
# it through `_read_primers`, which catches the deliberate raise on an unparseable
# file; loading it again here would escape that guard and throw, turning a Save
# into a 500 if the file changed underneath us between the two reads.
function _pair_pipeline_refs_removed(doc::AbstractDict, current::AbstractDict)
    was = Set(PrimersLibrary.pair_names(current))
    now = Set(PrimersLibrary.pair_names(doc))
    removed = setdiff(was, now)
    isempty(removed) && return Any[]
    refs = _cascade_refs("cutadapt.primer_pairs")
    warnings = Any[]
    for name in sort(collect(removed))
        haskey(refs, name) || continue
        push!(warnings, Dict("pair" => name, "referenced_by" => refs[name]))
    end
    warnings
end

# Parse a request body into a primers document. A body that is absent, not JSON,
# or JSON that is not a top-level object would otherwise throw out of the route
# and surface as a bare 500; this route backs a Save button, where a malformed
# request is a plausible client bug and deserves an actionable message.
# Returns the document, or an HTTP.Response error.
function _primers_body(body::AbstractString)
    parsed = try
        JSON3.read(body)
    catch e
        return json_error(400, "invalid_json",
            "Request body is not valid JSON: $(sprint(showerror, e))")
    end
    parsed isa JSON3.Object || return json_error(400, "invalid_json",
        "Request body must be a JSON object with Forward, Reverse and Pairs")
    _to_plain(parsed)
end

# The whole primers document (Forward, Reverse, Pairs) in canonical shape.
@get "/api/v1/primers/document" function(req)
    doc = _read_primers()
    doc isa HTTP.Response && return doc
    json(doc)
end

# Replace the whole primers document. Validated before the write lands on disk;
# a pair naming an absent primer is rejected 400 with the file unchanged. The
# response carries any cross-file warnings: a dropped pair that some project's
# config cascade still resolves to, whether or not any pipeline.yml names it,
# since a project may inherit the pair from the global config or the factory
# defaults rather than naming it itself.
# The read of the current document comes first: when the file on disk is corrupt
# we refuse the write rather than let it be overwritten from an empty editor.
@put "/api/v1/primers" function(req)
    current = _read_primers()
    current isa HTTP.Response && return current
    doc = _primers_body(String(req.body))
    doc isa HTTP.Response && return doc
    warnings = _pair_pipeline_refs_removed(doc, current)
    result = _save_primers(doc)
    result isa HTTP.Response && return result
    json(Dict("document" => result, "warnings" => warnings))
end

@get "/api/v1/studies/{study}/config" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    json(_resolve_config(study))
end

@patch "/api/v1/studies/{study}/config" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(req.body)
    for (k, _) in body
        string(k) in _ALLOWED_CONFIG_KEYS || return json_error(400, "invalid_config_key",
            "Config key '$(string(k))' is not a recognised pipeline option")
    end
    path = joinpath(ServerState.data_dir(), study, "pipeline.yml")
    for (k, v) in body
        _write_override(path, string(k), v)
    end
    json(_resolve_config(study))
end

@delete "/api/v1/studies/{study}/config/{key}" function(req, study::String, key::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    path = joinpath(ServerState.data_dir(), study, "pipeline.yml")
    _delete_override(path, key)
    json(_resolve_config(study))
end

## Override indicators - which downstream entities override a given level's keys
# Returns { "dotted.key": ["group1", "run1", ...] } for each study-level key
# that has a group or run override.
@get "/api/v1/studies/{study}/config/overrides" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    overrides = Dict{String,Vector{String}}()
    # Check group-level pipeline.yml files
    for group in _group_names(study)
        group_cfg = _flatten(_load_yml(joinpath(ServerState.data_dir(), study, group, "pipeline.yml")))
        for k in keys(group_cfg)
            push!(get!(overrides, k, String[]), group)
        end
        # Check runs within this group
        for run in _group_run_names(study, group)
            run_cfg = _flatten(_load_yml(joinpath(ServerState.data_dir(), study, group, run, "pipeline.yml")))
            for k in keys(run_cfg)
                push!(get!(overrides, k, String[]), "$group/$run")
            end
        end
    end
    # Check direct (ungrouped) runs
    for run in _run_names(study)
        run_cfg = _flatten(_load_yml(joinpath(ServerState.data_dir(), study, run, "pipeline.yml")))
        for k in keys(run_cfg)
            push!(get!(overrides, k, String[]), run)
        end
    end
    json(overrides)
end

# Returns { "dotted.key": ["run1", ...] } for each group-level key
# that has a run override.
@get "/api/v1/studies/{study}/groups/{group}/config/overrides" function(req, study::String, group::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    overrides = Dict{String,Vector{String}}()
    for run in _group_run_names(study, group)
        run_cfg = _flatten(_load_yml(joinpath(ServerState.data_dir(), study, group, run, "pipeline.yml")))
        for k in keys(run_cfg)
            push!(get!(overrides, k, String[]), run)
        end
    end
    json(overrides)
end

## Group config endpoints
@get "/api/v1/studies/{study}/groups/{group}/config" function(req, study::String, group::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    json(_resolve_config(study, nothing, group))
end

@patch "/api/v1/studies/{study}/groups/{group}/config" function(req, study::String, group::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    body = JSON3.read(req.body)
    for (k, _) in body
        string(k) in _ALLOWED_CONFIG_KEYS || return json_error(400, "invalid_config_key",
            "Config key '$(string(k))' is not a recognised pipeline option")
    end
    path = joinpath(ServerState.data_dir(), study, group, "pipeline.yml")
    for (k, v) in body
        _write_override(path, string(k), v)
    end
    json(_resolve_config(study, nothing, group))
end

@delete "/api/v1/studies/{study}/groups/{group}/config/{key}" function(req, study::String,
                                                                            group::String,
                                                                            key::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    path = joinpath(ServerState.data_dir(), study, group, "pipeline.yml")
    _delete_override(path, key)
    json(_resolve_config(study, nothing, group))
end

## Run config endpoints
# Helper: find all valid run names including those inside groups
function _all_run_names(study::String)
    runs = copy(_run_names(study))
    for group in _group_names(study)
        append!(runs, _group_run_names(study, group))
    end
    unique!(runs)
end

@get "/api/v1/studies/{study}/runs/{run}/config" function(req, study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    group = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    json(_resolve_config(study, run, group))
end

@patch "/api/v1/studies/{study}/runs/{run}/config" function(req, study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    group = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    run_path = isnothing(group) ? run : joinpath(group, run)
    body = JSON3.read(req.body)
    for (k, _) in body
        string(k) in _ALLOWED_CONFIG_KEYS || return json_error(400, "invalid_config_key",
            "Config key '$(string(k))' is not a recognised pipeline option")
    end
    path = joinpath(ServerState.data_dir(), study, run_path, "pipeline.yml")
    for (k, v) in body
        _write_override(path, string(k), v)
    end
    json(_resolve_config(study, run, group))
end

@delete "/api/v1/studies/{study}/runs/{run}/config/{key}" function(req, study::String,
                                                                        run::String,
                                                                        key::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    group = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    run_path = isnothing(group) ? run : joinpath(group, run)
    path = joinpath(ServerState.data_dir(), study, run_path, "pipeline.yml")
    _delete_override(path, key)
    json(_resolve_config(study, run, group))
end
