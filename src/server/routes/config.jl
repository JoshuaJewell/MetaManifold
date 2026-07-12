# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/studies/{study}/config
#         /api/v1/studies/{study}/runs/{run}/config
using JSON3, YAML

const _config_file_lock = ReentrantLock()

## Config resolution
function _load_yml(path::String)
    isfile(path) ? something(YAML.load_file(path), Dict()) : Dict()
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
        tmp = path * ".tmp"
        open(tmp, "w") do io; YAML.write(io, cfg) end
        mv(tmp, path; force=true)
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
        tmp = path * ".tmp"
        open(tmp, "w") do io
            YAML.write(io, cfg)
        end
        mv(tmp, path; force=true)
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
        tmp = path * ".tmp"
        open(tmp, "w") do io
            YAML.write(io, cfg)
        end
        mv(tmp, path; force=true)
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
