# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: pipeline execution
#
# Every job begins by calling write_run_config() for the target run(s) so that
# any config changes made in the UI are picked up before execution. The
# existing checkpoint/hash logic then skips stages whose inputs are unchanged.
using JSON3, RCall

const _r_lock = ReentrantLock()

## Tagging helpers

# Build the tagging dict passed to `load_results_db` from the run config and the
# project's config directory. Returns `nothing` when the tagging block is absent.
function _tagging_cfg(project, run_cfg::Dict)
    tag = get(run_cfg, "tagging", nothing)
    isnothing(tag) && return nothing
    Dict(
        "source"           => string(get(tag, "source", "VSEARCH")),
        "max_x"            => Int(get(tag, "max_x", -1)),
        "category_sets"    => Vector{String}(get(tag, "category_sets", String[])),
        "compositions_dir" => joinpath(project.config_dir, "compositions"),
        "filters_dir"      => joinpath(project.config_dir, "filters"),
    )
end

## Stage execution helpers
function _with_r_lock(action::Function, run_label::String, steps::AbstractVector{<:AbstractString}=String[];
                      reset_workspace::Bool=true)
    suffix = isempty(steps) ? "" : " (" * join(steps, " -> ") * ")"
    @info "[$run_label] DADA2: Waiting for R lock$suffix..."
    lock(_r_lock) do
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

function _run_full_pipeline(study::String, run::String, db_config::String,
                             dbs::Dict, db_name::String;
                             group::Union{String,Nothing}=nothing)
    project  = _project_ctx(study, run, group)
    db_meta  = make_db_meta(db_config, db_name)
    trimmed  = cutadapt(project)

    run_cfg          = YAML.load_file(write_run_config(project))
    classify_enabled = get(get(get(run_cfg, "dada2", Dict()), "taxonomy", Dict()), "enabled", true) != false
    vsearch_enabled  = get(get(run_cfg, "vsearch", Dict()), "enabled", true) != false
    swarm_enabled    = get(get(run_cfg, "swarm",   Dict()), "enabled", true) != false

    run_label = isnothing(group) ? run : "$group/$run"
    asvs = _with_r_lock(run_label) do
        dada2(project, trimmed;
              taxonomy_db=classify_enabled ? dbs["$(db_name)_dada2"] : nothing,
              skip_taxonomy=!classify_enabled)
    end
    @info "[$run_label] DADA2: Complete"
    if get(get(run_cfg, "cdhit", Dict()), "enabled", false) == true
        asvs = cdhit(project, asvs)
    end

    otus = swarm_enabled ? swarm(project, asvs) : nothing

    # VSEARCH: run ASV and OTU paths concurrently when both are needed
    asv_tax_task = vsearch_enabled ?
        Threads.@spawn(vsearch(project, asvs, dbs["$(db_name)_vsearch"])) : nothing
    otu_tax_task = (swarm_enabled && !isnothing(otus) && vsearch_enabled) ?
        Threads.@spawn(vsearch(project, otus,  dbs["$(db_name)_vsearch"])) : nothing

    asv_tax    = isnothing(asv_tax_task) ? nothing : fetch(asv_tax_task)
    asv_merged = _merge_taxa_routed(project, asvs, asv_tax, db_meta; vsearch_enabled)

    merged = if !isnothing(otu_tax_task)
        otu_tax    = fetch(otu_tax_task)
        otu_merged = merge_taxa_otu(project, otus, otu_tax, db_meta)
        MergedTables(merge(asv_merged.tables, otu_merged.tables))
    else
        asv_merged
    end

    # Load results into DuckDB
    swarm_dir = joinpath(project.dir, "swarm")
    load_results_db(joinpath(project.dir, "merged");
                    swarm_dir = isdir(swarm_dir) ? swarm_dir : nothing,
                    tagging   = _tagging_cfg(project, run_cfg))

    GC.gc(false)
    merged
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
        write_run_config(project)
        multiqc(project)
        GC.gc(false)
        return
    end

    db_meta     = make_db_meta(db_config, db_name)
    run_dir     = project.dir
    config_path = write_run_config(project)
    input_dir   = joinpath(run_dir, "cutadapt")
    ws_root     = joinpath(run_dir, "dada2")

    target = get(_STAGE_STOP, stage, stage)
    target_idx = findfirst(==(target), _PIPELINE_ORDER)
    isnothing(target_idx) && error("Unknown stage: $stage")

    steps = _PIPELINE_ORDER[1:target_idx]

    # cutadapt (no R)
    if "cutadapt" in steps
        cutadapt(project)
    end

    # DADA2 sub-stages share R state - run under a single lock
    dada2_steps = filter(s -> s in ("prefilter_qc", "filter_trim", "learn_errors",
                                    "denoise", "filter_length", "chimera_removal",
                                    "assign_taxonomy"), steps)
    if !isempty(dada2_steps)
        _with_r_lock(basename(run_dir), dada2_steps) do
            for step in dada2_steps
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

    # Post-DADA2 stages (no R)
    run_cfg         = YAML.load_file(config_path)
    vsearch_enabled = get(get(run_cfg, "vsearch", Dict()), "enabled", true) != false
    swarm_enabled   = get(get(run_cfg, "swarm",   Dict()), "enabled", true) != false
    for step in steps
        if step == "cdhit"
            if get(get(run_cfg, "cdhit", Dict()), "enabled", false) == true
                asvs = _asvresult_from_disk(run_dir)
                cdhit(project, asvs)
            end
        elseif step == "swarm"
            if swarm_enabled
                asvs = _asvresult_from_disk(run_dir)
                swarm(project, asvs)
            end
        elseif step == "vsearch"
            if vsearch_enabled
                asvs = _asvresult_from_disk(run_dir)
                vsearch(project, asvs, dbs["$(db_name)_vsearch"])
                otus = _oturesult_from_disk(run_dir)
                if !isnothing(otus) && swarm_enabled
                    vsearch(project, otus, dbs["$(db_name)_vsearch"])
                end
            end
            asvs = _asvresult_from_disk(run_dir)
            otus = swarm_enabled ? _oturesult_from_disk(run_dir) : nothing
            _run_merge_taxa(project, asvs, otus, db_meta)
        elseif step == "merge_taxa"
            asvs = _asvresult_from_disk(run_dir)
            otus = swarm_enabled ? _oturesult_from_disk(run_dir) : nothing
            _run_merge_taxa(project, asvs, otus, db_meta)
        end
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
        _run_full_pipeline(study, run, db_cfg, dbs, db_name; group=grp)
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
