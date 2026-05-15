# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/studies/{study}/runs
using JSON3, Dates, YAML

const STAGES = [
    "fastqc", "cutadapt", "dada2_denoise", "dada2_classify", "cdhit", "swarm",
    "vsearch", "merge_taxa"
]

# Stages that are independent of the main pipeline cascade.
# Their status is shown in the UI but they never propagate cascade_stale.
const INDEPENDENT_STAGES = Set(["fastqc"])

# Map coarse UI stages to the fine-grained sub-stages that run within them.
# Used to detect "running" status when a sub-stage job is active.
const _SUBSTAGES = Dict(
    "dada2_denoise"  => Set(["prefilter_qc", "filter_trim", "learn_errors",
                             "denoise", "filter_length", "chimera_removal"]),
    "dada2_classify" => Set(["assign_taxonomy"]),
)

# DADA2 sub-stages (individually runnable from the UI)
const DADA2_SUBSTAGES = [
    "prefilter_qc", "filter_trim", "learn_errors", "denoise",
    "filter_length", "chimera_removal", "assign_taxonomy"
]

const ALL_RUNNABLE_STAGES = vcat(STAGES, DADA2_SUBSTAGES)

# Maps each stage to the files whose existence (and mtime) indicate completion.
const STAGE_OUTPUTS = Dict(
    "cutadapt"        => run_dir -> joinpath(run_dir, "cutadapt"),
    "fastqc"          => run_dir -> joinpath(run_dir, "QC", "multiqc_report.html"),
    "dada2_denoise"   => run_dir -> joinpath(run_dir, "dada2", "Checkpoints", "ckpt_chimera.RData"),
    "dada2_classify"  => run_dir -> joinpath(run_dir, "dada2", "Checkpoints", "checkpoint.RData"),
    "cdhit"           => run_dir -> joinpath(run_dir, "cdhit", "asvs.fasta"),
    "swarm"           => run_dir -> joinpath(run_dir, "swarm", "otu_table.csv"),
    "vsearch"         => run_dir -> joinpath(run_dir, "vsearch", "taxonomy.tsv"),
    "merge_taxa"      => run_dir -> joinpath(run_dir, "merged", "merged.csv"),
)

# Maps each coarse stage to its config hash file(s) and corresponding config
# section strings (as used by `_section_stale`).  When any hash is stale the
# stage's outputs are outdated.
const STAGE_HASHES = Dict(
    "cutadapt"      => run_dir -> [(
        joinpath(run_dir, "cutadapt", "config.hash"),
        stage_sections(:cutadapt),
    )],
    "fastqc"        => run_dir -> [(
        joinpath(run_dir, "QC", "config.hash"),
        stage_sections(:fastqc_multiqc),
    )],
    "dada2_denoise" => run_dir -> [
        (joinpath(run_dir, "dada2", "Checkpoints", "filter_trim.hash"),
         stage_sections(:dada2_filter_trim)),
        (joinpath(run_dir, "dada2", "Checkpoints", "learn_errors.hash"),
         stage_sections(:dada2_learn_errors)),
        (joinpath(run_dir, "dada2", "Checkpoints", "denoise.hash"),
         stage_sections(:dada2_denoise)),
        (joinpath(run_dir, "dada2", "Checkpoints", "filter_length.hash"),
         stage_sections(:dada2_filter_length)),
        (joinpath(run_dir, "dada2", "Checkpoints", "chimera_removal.hash"),
         stage_sections(:dada2_chimera_removal)),
    ],
    "dada2_classify" => run_dir -> [(
        joinpath(run_dir, "dada2", "Checkpoints", "assign_taxonomy.hash"),
        stage_sections(:dada2_assign_taxonomy),
    )],
    "cdhit"         => run_dir -> [(
        joinpath(run_dir, "cdhit", "config.hash"),
        stage_sections(:cdhit),
    )],
    "swarm"         => run_dir -> [(
        joinpath(run_dir, "swarm", "config.hash"),
        stage_sections(:swarm),
    )],
    "vsearch"       => run_dir -> [
        (joinpath(run_dir, "vsearch", "config.hash"),
         stage_sections(:vsearch)),
        (joinpath(run_dir, "swarm", "vsearch", "config.hash"),
         stage_sections(:vsearch)),
    ],
    "merge_taxa"    => run_dir -> [
        (joinpath(run_dir, "merged", "config.hash"),
         stage_sections(:merge_taxa)),
        (joinpath(run_dir, "merged", "config_otu.hash"),
         stage_sections(:merge_taxa)),
    ],
)

function _load_run_config(run_dir::String)::Union{Dict,Nothing}
    config_path = joinpath(run_dir, "run_config.yml")
    isfile(config_path) || return nothing
    cfg = YAML.load_file(config_path)
    cfg isa Dict ? cfg : nothing
end

function _config_flag(cfg::Union{Dict,Nothing}, keys::Vector{String}, default::Bool)::Bool
    isnothing(cfg) && return default
    d = cfg
    for k in keys
        d = get(d, k, nothing)
        d isa Dict || return default
    end
    get(d, "enabled", default) == true
end
# Convenience overload for callers that don't pre-load config.
_config_flag(run_dir::String, keys::Vector{String}, default::Bool) =
    _config_flag(_load_run_config(run_dir), keys, default)

_cdhit_enabled(cfg)    = _config_flag(cfg, ["cdhit"], false)
_classify_enabled(cfg) = _config_flag(cfg, ["dada2", "taxonomy"], true)
_vsearch_enabled(cfg)  = _config_flag(cfg, ["vsearch"], true)
_swarm_enabled(cfg)    = _config_flag(cfg, ["swarm"], true)

# Ensure run_config.yml is up to date with the config cascade.
# Without this, config changes made through the PATCH API are invisible to
# the staleness checker because run_config.yml is only regenerated during
# pipeline execution.
function _ensure_run_config(study::String, run::String;
                             group::Union{String,Nothing}=nothing)
    data_rel    = isnothing(group) ? run : joinpath(group, run)
    project_rel = data_rel  # projects/ mirrors data/ layout
    project_dir = joinpath(ServerState.projects_dir(), study, project_rel)
    isdir(project_dir) || return  # project not initialised yet
    config_dir     = joinpath(dirname(ServerState.data_dir()), "config")
    data_dir       = joinpath(ServerState.data_dir(), study, data_rel)
    data_study_dir = joinpath(ServerState.data_dir(), study)

    # Respect pool_children for config resolution.
    if _is_pooled(data_dir)
        child_dirs = String[]
        for (child, _, child_files) in walkdir(data_dir; follow_symlinks=true)
            child == data_dir && continue
            any(f -> endswith(f, ".fastq.gz"), child_files) && push!(child_dirs, child)
        end
        data_dirs = isempty(child_dirs) ? [data_dir] : child_dirs
    else
        data_dirs = [data_dir]
    end

    ctx = ProjectCtx(project_dir, config_dir, data_dir,
                     joinpath(ServerState.projects_dir(), study), data_study_dir,
                     data_dirs)
    write_run_config(ctx)
end

# Stages whose multiple hash files are written in strict sequential order, so a
# later file having an older mtime than an earlier one means the downstream
# sub-stage hasn't re-run since its upstream changed.
# "vsearch" is intentionally excluded: its two hash files (ASV path and OTU/SWARM
# path) are written by concurrent Threads.@spawn tasks, so their mtime ordering
# is non-deterministic and must not be used as a staleness signal.
# "merge_taxa" is intentionally excluded: its two hash files represent parallel
# paths (ASV merge vs OTU merge), not sequential sub-stages. When swarm/OTU is
# disabled only the ASV hash updates, making mtime ordering meaningless.
const ORDERED_HASH_STAGES = Set(["dada2_denoise"])

# Check whether a completed stage's config has changed since it last ran.
# For ordered multi-hash stages (e.g. dada2_denoise), also detect when an earlier
# sub-stage was re-run more recently than a later one - meaning the later
# sub-stage's outputs are based on stale inputs even if its own config
# sections haven't changed.
function _stage_config_stale(stage::String, run_dir::String)::Bool
    config_path = joinpath(run_dir, "run_config.yml")
    isfile(config_path) || return true  # no config - cannot verify freshness; assume stale
    hash_entries = STAGE_HASHES[stage](run_dir)
    any_found = false
    for (hash_file, sections) in hash_entries
        isfile(hash_file) || continue  # hash file may not exist (e.g. OTU vsearch when no OTUs)
        any_found = true
        _section_stale(config_path, sections, hash_file) && return true
    end
    # If the stage has hash entries but none were written, it ran but failed
    # before _write_section_hash (e.g. cutadapt with wrong file naming).
    # Treat as stale so the UI surfaces it for re-run rather than hiding it as green.
    !any_found && !isempty(hash_entries) && return true
    # Ordered sub-stage cascade: if an earlier hash file is newer than a later
    # one, the later sub-stage hasn't re-run since its upstream was updated.
    # Only applies to stages with genuinely sequential sub-stages.
    if stage in ORDERED_HASH_STAGES && length(hash_entries) > 1
        prev_mtime = 0.0
        for (hash_file, _) in hash_entries
            isfile(hash_file) || continue
            mt = mtime(hash_file)
            if mt < prev_mtime
                return true
            end
            prev_mtime = mt
        end
    end
    false
end

# Return the dotted config keys that changed for a stale stage.
# Also flags sub-stages whose inputs are stale (upstream re-run more recently).
function _stage_stale_keys(stage::String, run_dir::String)::Vector{String}
    config_path = joinpath(run_dir, "run_config.yml")
    isfile(config_path) || return String["(config missing)"]
    hash_entries = STAGE_HASHES[stage](run_dir)
    keys = String[]
    for (hash_file, sections) in hash_entries
        isfile(hash_file) || continue
        _section_stale(config_path, sections, hash_file) || continue
        append!(keys, _stale_keys(config_path, sections, hash_file))
    end
    # Detect mtime-based staleness within ordered sub-stages only.
    if stage in ORDERED_HASH_STAGES && length(hash_entries) > 1
        prev_mtime = 0.0
        upstream_stale = false
        for (hash_file, sections) in hash_entries
            isfile(hash_file) || continue
            mt = mtime(hash_file)
            if mt < prev_mtime
                upstream_stale = true
            end
            if upstream_stale
                # Mark all config sections of this sub-stage as stale (upstream changed)
                for sec in strip.(split(sections, ","))
                    push!(keys, "$sec (upstream re-run)")
                end
            end
            prev_mtime = mt
        end
    end
    unique(sort(keys))
end

function _stage_status(stage::String, run_dir::String; study::String="",
                       jobs::Vector=JobQueue.list_jobs())
    sentinel = STAGE_OUTPUTS[stage](run_dir)
    if isdir(sentinel) || isfile(sentinel)
        return "complete"
    end
    run_name = basename(run_dir)
    substages = get(_SUBSTAGES, stage, Set{String}())
    running_jobs = filter(jobs) do j
        j.status in (JobQueue.queued, JobQueue.running) || return false
        if j.type == "pipeline"
            isnothing(j.run) && return !isempty(study) && j.study == study
            return j.run == run_name
        end
        js = something(j.stage, "")
        (js == stage || js in substages) && occursin(run_name, something(j.run, ""))
    end
    isempty(running_jobs) ? "not_started" : "running"
end

# Compute statuses for all stages with cascade: once a stage is stale or
# missing, all subsequent completed stages are also stale.
# Returns (statuses, stale_keys) where stale_keys maps stage to changed dotted keys.
function _all_stage_statuses(run_dir::String; study::String="")
    statuses   = Dict{String,String}()
    stale_keys = Dict{String,Vector{String}}()
    cascade_stale = false
    cfg = _load_run_config(run_dir)
    jobs = JobQueue.list_jobs()
    for stage in STAGES
        if stage == "cdhit"          && !_cdhit_enabled(cfg);    statuses[stage] = "disabled"; continue; end
        if stage == "dada2_classify" && !_classify_enabled(cfg); statuses[stage] = "disabled"; continue; end
        if stage == "vsearch"        && !_vsearch_enabled(cfg);  statuses[stage] = "disabled"; continue; end
        if stage == "swarm"          && !_swarm_enabled(cfg);    statuses[stage] = "disabled"; continue; end

        raw = _stage_status(stage, run_dir; study, jobs)

        # Independent stages (e.g. fastqc) show their own status but never
        # affect or inherit cascade_stale - they are orthogonal to the pipeline.
        if stage in INDEPENDENT_STAGES
            if raw == "complete" && _stage_config_stale(stage, run_dir)
                statuses[stage] = "stale"
                stale_keys[stage] = _stage_stale_keys(stage, run_dir)
            else
                statuses[stage] = raw
            end
            continue
        end

        if raw == "complete"
            own_stale = _stage_config_stale(stage, run_dir)
            if cascade_stale || own_stale
                statuses[stage] = "stale"
                if own_stale
                    stale_keys[stage] = _stage_stale_keys(stage, run_dir)
                end
                cascade_stale = true
            else
                statuses[stage] = "complete"
            end
        else
            statuses[stage] = raw
            # A missing or running upstream stage means downstream outputs are stale
            if raw == "not_started"
                cascade_stale = true
            end
        end
    end
    statuses, stale_keys
end

function _last_run(stage::String, run_dir::String)
    sentinel = STAGE_OUTPUTS[stage](run_dir)
    path = isdir(sentinel) ? sentinel : isfile(sentinel) ? sentinel : nothing
    isnothing(path) && return nothing
    string(unix2datetime(mtime(path))) * "Z"
end

"""Return sub-group names for a pooled directory (child dirs containing FASTQs)."""
function _subgroup_names(data_dir::String)
    names = String[]
    isdir(data_dir) || return names
    for (child, _, child_files) in walkdir(data_dir; follow_symlinks=true)
        child == data_dir && continue
        any(f -> endswith(f, ".fastq.gz"), child_files) || continue
        push!(names, replace(basename(child), " " => "_"))
    end
    sort(names)
end

function _run_data(study::String, run::String;
                   group::Union{String,Nothing}=nothing)
    resolved    = isnothing(group) ? _run_group(study, run) : group
    data_rel    = isnothing(resolved) ? run : joinpath(resolved, run)
    run_dir     = joinpath(ServerState.projects_dir(), study, data_rel)
    data_dir    = joinpath(ServerState.data_dir(), study, data_rel)
    samples     = _sample_names(study, data_rel)

    pooled    = _is_pooled(data_dir)
    subgroups = pooled ? _subgroup_names(data_dir) : String[]

    _ensure_run_config(study, run; group=resolved)
    statuses, stale_keys = _all_stage_statuses(run_dir; study)
    stages = Dict(s => (;
        status     = statuses[s],
        last_run   = _last_run(s, run_dir),
        stale_keys = get(stale_keys, s, String[]),
    ) for s in STAGES)

    (; name=run, study, group=resolved, sample_count=length(samples), samples,
     stages, pooled, subgroups)
end

@get "/api/v1/studies/{study}/runs" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    runs = map(_run_names(study)) do run
        run_dir  = joinpath(ServerState.projects_dir(), study, run)
        data_dir = joinpath(ServerState.data_dir(), study, run)
        samples  = _sample_names(study, run)
        pooled   = _is_pooled(data_dir)
        _ensure_run_config(study, run)
        statuses, _ = _all_stage_statuses(run_dir; study)
        stages   = Dict(s => (; status=statuses[s]) for s in STAGES)
        (; name=run, study, sample_count=length(samples), stages, pooled,
         subgroups=pooled ? _subgroup_names(data_dir) : String[])
    end
    json(runs)
end

@get "/api/v1/studies/{study}/groups/{group}/runs" function(req, study::String, group::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    group in _group_names(study) || return json_error(404, "group_not_found",
                                                          "Group '$group' not found")
    runs = map(_group_run_names(study, group)) do run
        run_dir  = joinpath(ServerState.projects_dir(), study, group, run)
        data_dir = joinpath(ServerState.data_dir(), study, group, run)
        samples  = _sample_names(study, joinpath(group, run))
        pooled   = _is_pooled(data_dir)
        _ensure_run_config(study, run; group)
        statuses, _ = isdir(run_dir) ? _all_stage_statuses(run_dir; study) :
                      (Dict(s => "not_started" for s in STAGES), Dict{String,Vector{String}}())
        stages   = Dict(s => (; status=statuses[s]) for s in STAGES)
        (; name=run, study, group, sample_count=length(samples), stages, pooled,
         subgroups=pooled ? _subgroup_names(data_dir) : String[])
    end
    json(runs)
end

@get "/api/v1/studies/{study}/runs/{run}" function(req, study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found in study '$study'")
    group = get(queryparams(req), "group", nothing)
    json(_run_data(study, run; group))
end

## Run management
function _run_has_active_jobs(study::String, run::String)::Bool
    any(j -> j.status in (JobQueue.queued, JobQueue.running) && j.run == run,
        JobQueue.list_jobs(; study))
end

@post "/api/v1/studies/{study}/runs" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(String(req.body))
    name  = get(body, :name,  nothing)
    group = get(body, :group, nothing)
    isnothing(name) && return json_error(400, "missing_name", "Body must include 'name'")
    name = string(name)
    _valid_name(name) || return json_error(400, "invalid_name",
        "Name must contain only letters, digits, hyphens, underscores, or dots")
    all_run_names = _all_run_names(study)
    name in all_run_names && return json_error(409, "run_exists",
        "Run '$name' already exists in study '$study'")
    data_rel    = isnothing(group) ? name : joinpath(string(group), name)
    project_rel = data_rel
    mkpath(joinpath(ServerState.data_dir(),     study, data_rel))
    mkpath(joinpath(ServerState.projects_dir(), study, project_rel))
    json((; study, name, group=isnothing(group) ? nothing : string(group)))
end

@post "/api/v1/studies/{study}/runs/{run}/rename" function(req, study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    body = JSON3.read(String(req.body))
    new_name = get(body, :name, nothing)
    isnothing(new_name) && return json_error(400, "missing_name", "Body must include 'name'")
    new_name = string(new_name)
    _valid_name(new_name) || return json_error(400, "invalid_name",
        "Name must contain only letters, digits, hyphens, underscores, or dots")
    new_name == run && return json((; study, name=run))
    new_name in _all_run_names(study) && return json_error(409, "run_exists",
        "Run '$new_name' already exists")
    _run_has_active_jobs(study, run) && return json_error(409, "jobs_active",
        "Run '$run' has active jobs - wait for them to finish before renaming")
    group = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    old_rel = isnothing(group) ? run : joinpath(group, run)
    new_rel = isnothing(group) ? new_name : joinpath(group, new_name)
    mv(joinpath(ServerState.data_dir(),     study, old_rel),
       joinpath(ServerState.data_dir(),     study, new_rel); force=false)
    dst_projects = joinpath(ServerState.projects_dir(), study, new_rel)
    src_projects = joinpath(ServerState.projects_dir(), study, old_rel)
    isdir(src_projects) && mv(src_projects, dst_projects; force=false)
    json((; study, name=new_name, group=isnothing(group) ? nothing : group))
end

@delete "/api/v1/studies/{study}/runs/{run}" function(req, study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    _run_has_active_jobs(study, run) && return json_error(409, "jobs_active",
        "Run '$run' has active jobs - wait for them to finish before deleting")
    group   = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    rel     = isnothing(group) ? run : joinpath(group, run)
    rm(joinpath(ServerState.data_dir(),     study, rel); recursive=true, force=true)
    rm(joinpath(ServerState.projects_dir(), study, rel); recursive=true, force=true)
    json((; deleted=run))
end
