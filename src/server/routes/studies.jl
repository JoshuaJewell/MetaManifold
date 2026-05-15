# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/studies  and  /api/v1/init
using JSON3, YAML

## helpers
"""Check whether a directory's pipeline.yml contains `pool_children: true`."""
function _is_pooled(dir::String)::Bool
    yml = joinpath(dir, "pipeline.yml")
    isfile(yml) || return false
    cfg = YAML.load_file(yml)
    cfg isa Dict && get(cfg, "pool_children", false) == true
end

function _study_names()
    isdir(ServerState.data_dir()) || return String[]
    filter(readdir(ServerState.data_dir())) do name
        isdir(joinpath(ServerState.data_dir(), name))
    end
end

function _run_names(study::String)
    d = joinpath(ServerState.data_dir(), study)
    isdir(d) || return String[]
    filter(readdir(d)) do name
        sub = joinpath(d, name)
        isdir(sub) || return false
        # A pooled group appears as a run (its children are not independent runs).
        _is_pooled(sub) && return true
        !isempty(filter(f -> endswith(f, ".fastq.gz"), readdir(sub)))
    end
end

function _group_names(study::String)
    d = joinpath(ServerState.data_dir(), study)
    isdir(d) || return String[]
    # A group directory contains subdirectories (runs) but no fastq files directly,
    # or has been explicitly marked as a group via a .group marker file.
    # A directory with pool_children: true is a *run*, not a group.
    filter(readdir(d)) do name
        sub = joinpath(d, name)
        isdir(sub) || return false
        _is_pooled(sub) && return false
        isfile(joinpath(sub, ".group")) && return true  # UI-created empty group
        isempty(filter(f -> endswith(f, ".fastq.gz"), readdir(sub))) &&
        !isempty(filter(n -> isdir(joinpath(sub, n)), readdir(sub)))
    end
end

function _group_run_names(study::String, group::String)
    d = joinpath(ServerState.data_dir(), study, group)
    isdir(d) || return String[]
    filter(readdir(d)) do name
        sub = joinpath(d, name)
        isdir(sub) || return false
        _is_pooled(sub) && return true
        !isempty(filter(f -> endswith(f, ".fastq.gz"), readdir(sub)))
    end
end

function _run_group(study::String, run::String)
    for group in _group_names(study)
        if run in _group_run_names(study, group)
            return group
        end
    end
    return nothing
end

"""Return the projects/ directory for a run, resolving its group if needed."""
function _run_project_dir(study::String, run::String;
                          group::Union{String,Nothing}=nothing)
    resolved = isnothing(group) ? _run_group(study, run) : group
    rel = isnothing(resolved) ? run : joinpath(resolved, run)
    joinpath(ServerState.projects_dir(), study, rel)
end

"""Extract the optional `group` query parameter from a request."""
function _req_group(req)
    g = get(queryparams(req), "group", nothing)
    isnothing(g) || isempty(g) ? nothing : g
end

function _sample_names(study::String, run::String)
    d = joinpath(ServerState.data_dir(), study, run)
    isdir(d) || return String[]

    if _is_pooled(d)
        # Collect prefixed sample names from all child directories.
        names = String[]
        for (child, _, child_files) in walkdir(d; follow_symlinks=true)
            child == d && continue
            any(f -> endswith(f, ".fastq.gz"), child_files) || continue
            prefix = replace(basename(child), " " => "_") * "_"
            for f in child_files
                (endswith(f, "_R1.fastq.gz") || endswith(f, "_R1_001.fastq.gz")) || continue
                push!(names, prefix * replace(f, r"_R1(_001)?\.fastq\.gz$" => ""))
            end
        end
        return sort(names)
    end

    files = filter(f -> endswith(f, "_R1.fastq.gz") || endswith(f, "_R1_001.fastq.gz"),
                   readdir(d))
    map(f -> replace(f, r"_R1(_001)?\.fastq\.gz$" => ""), files)
end

function _active_job_count(study::String)
    jobs = JobQueue.list_jobs(; study)
    count(j -> j.status in (JobQueue.queued, JobQueue.running), jobs)
end

function _study_data(name::String)
    runs   = _run_names(name)
    groups = _group_names(name)
    (; name,
       run_count        = length(runs),
       group_count      = length(groups),
       active_job_count = _active_job_count(name),
       runs,
       groups)
end

function _ensure_all_projects()
    initialised = String[]
    for study in _study_names()
        proj_dir = joinpath(ServerState.projects_dir(), study)
        isdir(proj_dir) && continue
        try
            new_project(study;
                        data_dir     = ServerState.data_dir(),
                        projects_dir = ServerState.projects_dir(),
                        config_dir   = joinpath(dirname(ServerState.data_dir()), "config"))
            push!(initialised, study)
        catch e
            @warn "server: could not initialise project '$study'" exception=e
        end
    end
    initialised
end

## Name validation
# Valid entity names: letters, digits, hyphens, underscores, dots.
# No slashes, no leading dots (hidden files), no empty strings.
function _valid_name(name::String)::Bool
    !isempty(name) &&
    !startswith(name, ".") &&
    name != "." && name != ".." &&
    occursin(r"^[A-Za-z0-9_\-\.]+$", name)
end

## Active-job guard
function _study_has_active_jobs(study::String)::Bool
    any(j -> j.status in (JobQueue.queued, JobQueue.running),
        JobQueue.list_jobs(; study))
end

## Filesystem helpers
function _safe_move(src::String, dst::String)
    isdir(src) || return  # nothing to move
    isdir(dirname(dst)) || mkpath(dirname(dst))
    mv(src, dst; force=false)
end

## Routes
@post "/api/v1/init" function(req)
    initialised = _ensure_all_projects()
    json((; initialised))
end

@get "/api/v1/studies" function(req)
    studies = map(_study_names()) do name
        runs   = _run_names(name)
        groups = _group_names(name)
        (; name,
           run_count        = length(runs),
           group_count      = length(groups),
           active_job_count = _active_job_count(name))
    end
    json(studies)
end

@get "/api/v1/studies/{study}" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    json(_study_data(study))
end

## Study management
@post "/api/v1/studies" function(req)
    body = JSON3.read(String(req.body))
    name = get(body, :name, nothing)
    isnothing(name) && return json_error(400, "missing_name", "Body must include 'name'")
    name = string(name)
    _valid_name(name) || return json_error(400, "invalid_name",
        "Name must contain only letters, digits, hyphens, underscores, or dots")
    name in _study_names() && return json_error(409, "study_exists",
        "Study '$name' already exists")
    data_dir = joinpath(ServerState.data_dir(), name)
    mkpath(data_dir)
    # Initialise project skeleton
    try
        new_project(name;
                    data_dir     = ServerState.data_dir(),
                    projects_dir = ServerState.projects_dir(),
                    config_dir   = joinpath(dirname(ServerState.data_dir()), "config"))
    catch
    end
    json(_study_data(name))
end

@post "/api/v1/studies/{study}/rename" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(String(req.body))
    new_name = get(body, :name, nothing)
    isnothing(new_name) && return json_error(400, "missing_name", "Body must include 'name'")
    new_name = string(new_name)
    _valid_name(new_name) || return json_error(400, "invalid_name",
        "Name must contain only letters, digits, hyphens, underscores, or dots")
    new_name == study && return json(_study_data(study))
    new_name in _study_names() && return json_error(409, "study_exists",
        "Study '$new_name' already exists")
    _study_has_active_jobs(study) && return json_error(409, "jobs_active",
        "Study '$study' has active jobs - wait for them to finish before renaming")
    _safe_move(joinpath(ServerState.data_dir(),     study), joinpath(ServerState.data_dir(),     new_name))
    _safe_move(joinpath(ServerState.projects_dir(), study), joinpath(ServerState.projects_dir(), new_name))
    json(_study_data(new_name))
end

@delete "/api/v1/studies/{study}" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    _study_has_active_jobs(study) && return json_error(409, "jobs_active",
        "Study '$study' has active jobs - wait for them to finish before deleting")
    rm(joinpath(ServerState.data_dir(),     study); recursive=true, force=true)
    rm(joinpath(ServerState.projects_dir(), study); recursive=true, force=true)
    json((; deleted=study))
end

## Group management
@post "/api/v1/studies/{study}/groups" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(String(req.body))
    name = get(body, :name, nothing)
    isnothing(name) && return json_error(400, "missing_name", "Body must include 'name'")
    name = string(name)
    _valid_name(name) || return json_error(400, "invalid_name",
        "Name must contain only letters, digits, hyphens, underscores, or dots")
    name in _group_names(study) && return json_error(409, "group_exists",
        "Group '$name' already exists in study '$study'")
    name in _run_names(study) && return json_error(409, "name_conflict",
        "'$name' already exists as a run in study '$study'")
    group_dir = joinpath(ServerState.data_dir(), study, name)
    mkpath(group_dir)
    touch(joinpath(group_dir, ".group"))
    json((; study, name))
end

@post "/api/v1/studies/{study}/groups/{group}/rename" function(req, study::String, group::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    body = JSON3.read(String(req.body))
    new_name = get(body, :name, nothing)
    isnothing(new_name) && return json_error(400, "missing_name", "Body must include 'name'")
    new_name = string(new_name)
    _valid_name(new_name) || return json_error(400, "invalid_name",
        "Name must contain only letters, digits, hyphens, underscores, or dots")
    new_name == group && return json((; study, name=group))
    new_name in _group_names(study) && return json_error(409, "group_exists",
        "Group '$new_name' already exists")
    _study_has_active_jobs(study) && return json_error(409, "jobs_active",
        "Study has active jobs - wait for them to finish before renaming")
    _safe_move(joinpath(ServerState.data_dir(),     study, group),
               joinpath(ServerState.data_dir(),     study, new_name))
    _safe_move(joinpath(ServerState.projects_dir(), study, group),
               joinpath(ServerState.projects_dir(), study, new_name))
    json((; study, name=new_name))
end

@delete "/api/v1/studies/{study}/groups/{group}" function(req, study::String, group::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    _study_has_active_jobs(study) && return json_error(409, "jobs_active",
        "Study has active jobs - wait for them to finish before deleting")
    rm(joinpath(ServerState.data_dir(),     study, group); recursive=true, force=true)
    rm(joinpath(ServerState.projects_dir(), study, group); recursive=true, force=true)
    json((; deleted=group))
end
