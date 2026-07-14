# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: pipeline execution
#
# Every job begins by calling write_run_config() for the target run(s) so that
# any config changes made in the UI are picked up before execution. The
# existing checkpoint/hash logic then skips stages whose inputs are unchanged.
using JSON3, RCall
using MetaManifold.RRuntime: with_r_lock
const Provenance = MetaManifold.Provenance

## Tagging helpers

# Build the tagging dict passed to `load_results_db` from the run config and the
# project's config directory. Returns `nothing` when the tagging block is absent.
function _tagging_cfg(project, run_cfg::Dict)
    tag = get(run_cfg, "tagging", nothing)
    isnothing(tag) && return nothing
    Dict(
        "source"        => string(get(tag, "source", "VSEARCH")),
        "max_x"         => Int(get(tag, "max_x", -1)),
        "category_sets" => Vector{String}(get(tag, "category_sets", String[])),
        "library_path"  => joinpath(project.config_dir, "composition.yml"),
    )
end

## Stage execution helpers
# The R runtime is shared with the analysis endpoints; see `RRuntime`. A pipeline
# stage is work the user explicitly asked for, so it waits for the interpreter
# for as long as it takes rather than giving up.
function _with_r_lock(action::Function, run_label::String, steps::AbstractVector{<:AbstractString}=String[];
                      reset_workspace::Bool=true)
    suffix = isempty(steps) ? "" : " (" * join(steps, " -> ") * ")"
    @info "[$run_label] DADA2: Waiting for R lock$suffix..."
    with_r_lock() do
        @info "[$run_label] DADA2: R lock acquired"
        R"tryCatch({ while(sink.number() > 0) { sink(type='message'); sink() } }, error=function(e) NULL)"
        reset_workspace && R"rm(list=ls())"
        action()
    end
end

function _project_ctx(study::String, run::String,
                      group::Union{String,Nothing}=nothing)
    resolved  = isnothing(group) ? _run_group(study, run) : group
    data_rel  = isnothing(resolved) ? run : joinpath(resolved, run)
    config_dir  = joinpath(dirname(ServerState.data_dir()), "config")
    project_dir = joinpath(ServerState.projects_dir(), study, data_rel)
    data_dir    = joinpath(ServerState.data_dir(), study, data_rel)
    mkpath(project_dir)

    # When pool_children is set, collect child FASTQ directories.
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

    ProjectCtx(project_dir, config_dir, data_dir,
               joinpath(ServerState.projects_dir(), study),
               joinpath(ServerState.data_dir(), study),
               data_dirs)
end

## Provenance
# The R probe evaluates in the one shared interpreter, and a concurrent run may hold
# it for the length of a DADA2 denoise. `probe_r` defaults to giving up after 60s,
# which is right for an interactive analysis but wrong here: a pipeline stage is the
# work the user asked for, so it waits, exactly as `_with_r_lock` does. With the
# default, the second run of a multi-run study would abort its own preflight merely
# because the first run was busy.
#
# The probes are process-stable, so they are memoised. `_run_stage` is called once
# per stage press and would otherwise re-enter R and re-spawn six `--version`
# subprocesses each time; multiqc alone takes the better part of a second.
const _probe_cache = Dict{Any,Any}()
const _probe_lock  = ReentrantLock()

_memo(f::Function, key) = lock(_probe_lock) do
    get!(f, _probe_cache, key)
end

# Keyed on the binary's path, size and mtime, so a tool replaced mid-process is
# still noticed: the per-stage fidelity claim must survive the memoisation.
function _probe_tool_cached(probe)
    path = Provenance.default_bin_resolver(probe.name)
    stamp = isfile(path) ? (filesize(path), mtime(path)) : (0, 0.0)
    _memo(() -> Provenance.probe_tool(probe), (:tool, probe.name, path, stamp))
end

# Probing is a phase, not a side effect scattered through the stages: a run that
# cannot prove what produced it must fail before any compute, not forty minutes
# into DADA2. `preflight` probes exactly the components this config will invoke.
#
# The database config is parsed once per process rather than once per stage, and the
# database records are memoised too: without that, the study loop's concurrent runs
# would all stampede the same multi-gigabyte FASTA on a cold sidecar cache.
function _preflight(run_cfg::Dict, db_config::String, dbs::Dict, db_name::String)
    specs = _memo(() -> Provenance.database_specs(YAML.load_file(db_config), db_name;
                                                  resolved=dbs),
                  (:dbspecs, db_config, db_name))
    Provenance.preflight(run_cfg;
                         databases     = Dict(db_name => specs),
                         julia_prober  = () -> _memo(Provenance.probe_julia, :julia),
                         r_prober      = () -> _memo(() -> Provenance.probe_r(; timeout=nothing), :r),
                         database_prober = (name, s) -> _memo(() -> Provenance.probe_database(name, s),
                                                              (:db, name)),
                         tool_prober   = _probe_tool_cached)
end

# Open (or reopen) this run's Attestation. `write_attestation` merges into whatever
# is already on disk, so re-running one stage rewrites that stage alone; a run
# directory is an accretion and the other stages' records remain true.
function _attestation(study::String, run::String,
                      group::Union{String,Nothing}, run_cfg::Dict, config_path::String)
    Provenance.Attestation(;
        run    = Dict("study" => study,
                      "group" => isnothing(group) ? nothing : group,
                      "run"   => run),
        config = run_cfg,
        config_sha256 = Provenance.file_sha256(config_path))
end

_attest_path(project) = joinpath(project.dir, "attestation.yml")

## Stage vocabulary
# The two cascades describe the same work under different names: `_run_full_pipeline`
# records DADA2 as one stage, `_run_stage` records its seven sub-stages. Since the
# Attestation merges by stage name, recording either must RETIRE the other, or a full
# run followed by a re-run of `denoise` would leave a stale `dada2` record asserting
# one environment for outputs that a newer `denoise` record attributes to another,
# with nothing superseding it. That is precisely the dishonesty the per-stage design
# exists to prevent.
const _DADA2_STAGE     = "dada2"
const _DADA2_SUBSTAGES = ["prefilter_qc", "filter_trim", "learn_errors", "denoise",
                          "filter_length", "chimera_removal", "assign_taxonomy"]

_retired_by(name::AbstractString) =
    name == _DADA2_STAGE          ? _DADA2_SUBSTAGES :
    name in _DADA2_SUBSTAGES      ? [_DADA2_STAGE]    : String[]

function _write_attestation(att, path::String)
    recorded = Set(String(s["name"]) for s in att.doc["stages"])
    retired  = Set(Iterators.flatten(_retired_by(n) for n in recorded))
    if !isempty(retired) && isfile(path)
        existing = Provenance.read_attestation(path)
        filter!(s -> !(String(s["name"]) in retired), existing.doc["stages"])
        merged = Provenance.merge_attestations(existing, att)
        return Provenance.write_attestation(merged, path; merge_existing=false)
    end
    Provenance.write_attestation(att, path)
end

# Record a stage, timing the work it wraps and marking it failed if it throws. A run
# that dies midway must still leave the record of what it did manage to produce:
# outputs on disk with no provenance is the one state this whole apparatus exists to
# forbid, and it is exactly what a failing run would otherwise create.
function _attest(f::Function, att, env, name::AbstractString)
    started = Provenance.timestamp()
    try
        result = f()
        Provenance.record_stage!(att, name, env; started)
        return result
    catch
        Provenance.record_stage!(att, name, env; started, status="failed")
        rethrow()
    end
end

function _run_full_pipeline(study::String, run::String, db_config::String,
                             dbs::Dict, db_name::String;
                             group::Union{String,Nothing}=nothing)
    project  = _project_ctx(study, run, group)
    db_meta  = make_db_meta(db_config, db_name)

    # The config must be resolved before anything runs, so preflight can see which
    # components this run will actually invoke.
    config_path = write_run_config(project)
    run_cfg     = YAML.load_file(config_path)
    env         = _preflight(run_cfg, db_config, dbs, db_name)
    att         = _attestation(study, run, group, run_cfg, config_path)

    classify_enabled = get(get(get(run_cfg, "dada2", Dict()), "taxonomy", Dict()), "enabled", true) != false
    vsearch_enabled  = get(get(run_cfg, "vsearch", Dict()), "enabled", true) != false
    swarm_enabled    = get(get(run_cfg, "swarm",   Dict()), "enabled", true) != false
    cdhit_enabled    = get(get(run_cfg, "cdhit",   Dict()), "enabled", false) == true
    run_label        = isnothing(group) ? run : "$group/$run"

    # The Attestation is written whatever happens: a run that dies at vsearch has
    # still produced cutadapt and DADA2 outputs, and those must not sit on disk
    # unaccounted for.
    try
        trimmed = _attest(att, env, "cutadapt") do
            cutadapt(project)
        end

        asvs = _attest(att, env, "dada2") do
            _with_r_lock(run_label) do
                dada2(project, trimmed;
                      taxonomy_db=classify_enabled ? dbs["$(db_name)_dada2"] : nothing,
                      skip_taxonomy=!classify_enabled)
            end
        end
        @info "[$run_label] DADA2: Complete"

        if cdhit_enabled
            asvs = _attest(att, env, "cdhit") do
                cdhit(project, asvs)
            end
        end

        otus = swarm_enabled ? _attest(att, env, "swarm") do
            swarm(project, asvs)
        end : nothing

        # VSEARCH: run ASV and OTU paths concurrently when both are needed. Both are
        # fetched before the stage is recorded, or its finish time would precede the
        # OTU search it claims to cover.
        asv_tax, otu_tax = if vsearch_enabled
            _attest(att, env, "vsearch") do
                asv_task = Threads.@spawn(vsearch(project, asvs, dbs["$(db_name)_vsearch"]))
                otu_task = (swarm_enabled && !isnothing(otus)) ?
                    Threads.@spawn(vsearch(project, otus, dbs["$(db_name)_vsearch"])) : nothing
                (fetch(asv_task), isnothing(otu_task) ? nothing : fetch(otu_task))
            end
        else
            (nothing, nothing)
        end

        merged = _attest(att, env, "merge_taxa") do
            asv_merged = _merge_taxa_routed(project, asvs, asv_tax, db_meta; vsearch_enabled)
            if isnothing(otu_tax)
                asv_merged
            else
                otu_merged = merge_taxa_otu(project, otus, otu_tax, db_meta)
                MergedTables(merge(asv_merged.tables, otu_merged.tables))
            end
        end

        # Load results into DuckDB
        swarm_dir = joinpath(project.dir, "swarm")
        load_results_db(joinpath(project.dir, "merged");
                        swarm_dir = isdir(swarm_dir) ? swarm_dir : nothing,
                        tagging   = _tagging_cfg(project, run_cfg))

        GC.gc(false)
        return merged
    finally
        _write_attestation(att, _attest_path(project))
    end
end

# Canonical pipeline order. Every stage run executes from cutadapt through to
# the target so that skip guards validate all inputs.
const _PIPELINE_ORDER = [
    "cutadapt",
    "prefilter_qc", "filter_trim", "learn_errors", "denoise",
    "filter_length", "chimera_removal",
    "assign_taxonomy",
    "cdhit", "swarm", "vsearch", "merge_taxa",
]

# Coarse UI stages map to the last sub-stage they contain
const _STAGE_STOP = Dict(
    "dada2_denoise"  => "chimera_removal",
    "dada2_classify" => "assign_taxonomy",
)

function _run_stage(study::String, run::String, stage::String,
                    db_config::String, dbs::Dict, db_name::String;
                    group::Union{String,Nothing}=nothing)
    project = _project_ctx(study, run, group)

    # Independent stages: run directly without entering the cascade pipeline.
    if stage == "fastqc"
        cfg_path = write_run_config(project)
        run_cfg  = YAML.load_file(cfg_path)
        env = _preflight(run_cfg, db_config, dbs, db_name)
        att = _attestation(study, run, group, run_cfg, cfg_path)
        try
            _attest(att, env, "fastqc") do
                multiqc(project)
            end
        finally
            _write_attestation(att, _attest_path(project))
        end
        GC.gc(false)
        return
    end

    db_meta     = make_db_meta(db_config, db_name)
    run_dir     = project.dir
    config_path = write_run_config(project)
    input_dir   = joinpath(run_dir, "cutadapt")
    ws_root     = joinpath(run_dir, "dada2")

    # A stage re-run is the accretion case: this run's other stages were produced
    # by whatever was installed when THEY ran, and their records stay true. The
    # Attestation merges, so only the stages executed here are rewritten.
    stage_cfg = YAML.load_file(config_path)
    stage_env = _preflight(stage_cfg, db_config, dbs, db_name)
    stage_att = _attestation(study, run, group, stage_cfg, config_path)

    target = get(_STAGE_STOP, stage, stage)
    target_idx = findfirst(==(target), _PIPELINE_ORDER)
    isnothing(target_idx) && error("Unknown stage: $stage")

    steps = _PIPELINE_ORDER[1:target_idx]

    # Bind this run's Attestation and environment to the shared stage recorder.
    _record(f, name::AbstractString) = _attest(f, stage_att, stage_env, name)

    try
    # cutadapt (no R)
    if "cutadapt" in steps
        _record("cutadapt") do
            cutadapt(project)
        end
    end

    # DADA2 sub-stages share R state - run under a single lock
    dada2_steps = filter(s -> s in ("prefilter_qc", "filter_trim", "learn_errors",
                                    "denoise", "filter_length", "chimera_removal",
                                    "assign_taxonomy"), steps)
    if !isempty(dada2_steps)
        _with_r_lock(basename(run_dir), dada2_steps) do
            for step in dada2_steps
                _record(step) do
                    if step == "assign_taxonomy"
                        assign_taxonomy(config_path; input_dir, workspace_root=ws_root,
                                        taxonomy_db=dbs["$(db_name)_dada2"])
                        R"rm(list=ls()); gc()"
                    else
                        fn = getfield(DADA2, Symbol(step))
                        fn(config_path; input_dir, workspace_root=ws_root)
                        R"gc()"
                    end
                end
            end
        end
    end

    # Post-DADA2 stages (no R)
    vsearch_enabled = get(get(stage_cfg, "vsearch", Dict()), "enabled", true) != false
    swarm_enabled   = get(get(stage_cfg, "swarm",   Dict()), "enabled", true) != false
    for step in steps
        if step == "cdhit"
            if get(get(stage_cfg, "cdhit", Dict()), "enabled", false) == true
                _record("cdhit") do
                    cdhit(project, _asvresult_from_disk(run_dir))
                end
            end
        elseif step == "swarm"
            if swarm_enabled
                _record("swarm") do
                    swarm(project, _asvresult_from_disk(run_dir))
                end
            end
        elseif step == "vsearch"
            if vsearch_enabled
                _record("vsearch") do
                    asvs = _asvresult_from_disk(run_dir)
                    vsearch(project, asvs, dbs["$(db_name)_vsearch"])
                    otus = _oturesult_from_disk(run_dir)
                    if !isnothing(otus) && swarm_enabled
                        vsearch(project, otus, dbs["$(db_name)_vsearch"])
                    end
                end
            end
            _record("merge_taxa") do
                asvs = _asvresult_from_disk(run_dir)
                otus = swarm_enabled ? _oturesult_from_disk(run_dir) : nothing
                _run_merge_taxa(project, asvs, otus, db_meta)
            end
        elseif step == "merge_taxa"
            _record("merge_taxa") do
                asvs = _asvresult_from_disk(run_dir)
                otus = swarm_enabled ? _oturesult_from_disk(run_dir) : nothing
                _run_merge_taxa(project, asvs, otus, db_meta)
            end
        end
    end
    finally
        # Written whatever happens: a cascade that dies at vsearch has still
        # produced the stages before it, and those outputs must not go unrecorded.
        _write_attestation(stage_att, _attest_path(project))
    end

    GC.gc(false)
end

## Merge taxa helpers
# Route to the correct merge_taxa variant based on available vsearch output.
function _merge_taxa_routed(project, asvs, asv_tax, db_meta; vsearch_enabled::Bool=true)
    if vsearch_enabled && !isnothing(asv_tax)
        merge_taxa(project, asvs, asv_tax, db_meta)
    else
        merge_taxa_dada2_only(project, asvs, db_meta)
    end
end

# Called after vsearch (or merge_taxa) stage runs. Reads enabled flags from
# run_config.yml and uses whichever inputs are available.
function _run_merge_taxa(project, asvs, otus, db_meta)
    run_dir     = project.dir
    config_path = joinpath(run_dir, "run_config.yml")
    run_cfg     = isfile(config_path) ? YAML.load_file(config_path) : Dict()
    vsearch_enabled = get(get(run_cfg, "vsearch", Dict()), "enabled", true) != false

    asv_tax_path = joinpath(run_dir, "vsearch", "taxonomy.tsv")
    asv_tax      = (vsearch_enabled && isfile(asv_tax_path)) ?
                   TaxonomyHits(asv_tax_path) : nothing
    asv_merged   = _merge_taxa_routed(project, asvs, asv_tax, db_meta; vsearch_enabled)

    if !isnothing(otus)
        otu_tax_path = joinpath(run_dir, "swarm", "vsearch", "taxonomy.tsv")
        if vsearch_enabled && isfile(otu_tax_path)
            merge_taxa_otu(project, otus, TaxonomyHits(otu_tax_path), db_meta)
        end
    end

    swarm_dir = joinpath(run_dir, "swarm")
    load_results_db(joinpath(run_dir, "merged");
                    swarm_dir = isdir(swarm_dir) ? swarm_dir : nothing,
                    tagging   = _tagging_cfg(project, run_cfg))
    asv_merged
end

## Disk reconstruction helpers
function _asvresult_from_disk(run_dir::String)
    t = joinpath(run_dir, "dada2", "Tables")
    # Prefer CD-HIT output if it exists (CD-HIT runs after DADA2)
    cdhit_fasta = joinpath(run_dir, "cdhit", "asvs.fasta")
    fasta = isfile(cdhit_fasta) ? cdhit_fasta : joinpath(t, "asvs.fasta")
    ASVResult(fasta,
              joinpath(t, "seqtab_nochim.csv"),
              joinpath(t, "taxonomy.csv"))
end

function _oturesult_from_disk(run_dir::String)
    p = joinpath(run_dir, "swarm", "otu_table.csv")
    isfile(p) || return nothing
    f = joinpath(run_dir, "swarm", "seeds.fasta")
    OTUResult(f, p)
end

function _mergedtables_from_disk(run_dir::String)
    merge_dir = joinpath(run_dir, "merged")
    tables    = Dict{String,String}()
    isdir(merge_dir) || error("merge_taxa output not found - run merge_taxa first")
    for f in readdir(merge_dir; join=true)
        endswith(f, ".csv") || continue
        tables[splitext(basename(f))[1]] = f
    end
    MergedTables(tables)
end

## Routes
function _db_config_path()
    cfg = joinpath(dirname(ServerState.data_dir()), "config", "databases.yml")
    isfile(cfg) ? cfg : joinpath(dirname(ServerState.data_dir()), "config", "ci", "databases.yml")
end

function _load_dbs()
    path = _db_config_path()
    cfg  = YAML.load_file(path)
    db_name = get(get(cfg, "default", Dict()), "database", "pr2")
    dbs     = ensure_databases(path)
    db_name, dbs
end

@post "/api/v1/studies/{study}/pipeline" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    # Collect (group, run) pairs - preserves identity when run names are
    # duplicated across groups (e.g. Multiplex/Caecum and Vespa/Caecum).
    run_pairs = Tuple{Union{String,Nothing},String}[
        [(nothing, r) for r in _run_names(study)];
        [(g, r) for g in _group_names(study) for r in _group_run_names(study, g)]
    ]
    db_cfg  = _db_config_path()
    db_name, dbs = _load_dbs()

    job = submit_job!("pipeline"; study) do
        merged_results = Vector{Any}(undef, length(run_pairs))

        Threads.@threads for i in eachindex(run_pairs)
            grp, run = run_pairs[i]
            try
                merged_results[i] = _run_full_pipeline(study, run, db_cfg, dbs, db_name;
                                                       group=grp)
            catch e
                @error "Pipeline failed for run '$run' (group=$(repr(grp)))" exception=(e, catch_backtrace())
                merged_results[i] = nothing
            end
        end

        empty!(merged_results)

        # Consolidate the record. Each stage writes its own tool log, but nothing
        # gathers them: without this call `_TOOL_LOG_FILES` is a registry no one
        # reads, and a run's pipeline.log never carries the tool output that
        # explains it. `write_combined_log` finalises each run in turn, so the
        # runs must not be finalised individually here as well.
        projects = ProjectCtx[_project_ctx(study, r, g) for (g, r) in run_pairs]
        isempty(projects) || PipelineLog.write_combined_log(projects)
    end

    json(_job_to_namedtuple(job))
end

@post "/api/v1/studies/{study}/runs/{run}/pipeline" function(req, study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    grp     = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    db_cfg  = _db_config_path()
    db_name, dbs = _load_dbs()

    job = submit_job!("pipeline"; study, run) do
        result = _run_full_pipeline(study, run, db_cfg, dbs, db_name; group=grp)
        # Gather this run's tool logs into its pipeline.log; see the study route.
        PipelineLog.finalise_log(_project_ctx(study, run, grp))
        result
    end

    json(_job_to_namedtuple(job))
end

@post "/api/v1/studies/{study}/runs/{run}/stages/{stage}" function(req, study::String,
                                                                        run::String,
                                                                        stage::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                          "Run '$run' not found")
    stage in ALL_RUNNABLE_STAGES || return json_error(400, "unknown_stage", "Unknown stage: $stage")
    grp     = let g = _req_group(req); isnothing(g) ? _run_group(study, run) : g end
    db_cfg  = _db_config_path()
    db_name, dbs = _load_dbs()

    job = submit_job!("stage"; study, run, stage) do
        _run_stage(study, run, stage, db_cfg, dbs, db_name; group=grp)
    end

    json(_job_to_namedtuple(job))
end
