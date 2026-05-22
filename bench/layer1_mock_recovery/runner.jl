#!/usr/bin/env julia
# Drive MetaManifold's DADA2 pipeline against every dataset in datasets.yml
# whose FASTQ inputs have been fetched. Writes per-dataset pipeline configs
# under configs/, runs the pipeline with its outputs rooted under outputs/,
# and records the path to the produced tax_counts.csv in results/runs.yml
# for the evaluator to consume.
#
# Usage:
#   julia --project=. -t4 bench/layer1_mock_recovery/runner.jl
#   julia --project=. -t4 bench/layer1_mock_recovery/runner.jl mockrobiota_mock3
#
# A single positional argument restricts the run to one dataset key.

using YAML, Logging
using MetaManifold
using MetaManifold.DADA2

const BENCH_DIR    = @__DIR__
const REGISTRY     = joinpath(BENCH_DIR, "datasets.yml")
const DATA_DIR     = joinpath(BENCH_DIR, "data")
const CONFIGS_DIR  = joinpath(BENCH_DIR, "configs")
const OUTPUTS_DIR  = joinpath(BENCH_DIR, "outputs")
const RESULTS_DIR  = joinpath(BENCH_DIR, "results")
const DEFAULTS_YML = joinpath(dirname(dirname(BENCH_DIR)), "config", "defaults", "pipeline.yml")

# Build a per-dataset config by merging defaults with dataset-specific overrides.
# The override scope is intentionally narrow: primers, taxonomy database, and
# annotation max_rank. Everything else inherits from config/defaults/pipeline.yml
# so the benchmark exercises the same code paths a real study would.
function _write_config(key::AbstractString, entry::Dict)::String
    base = YAML.load_file(DEFAULTS_YML)

    primers = get(entry, "primers", "EMP")
    base["cutadapt"]["primer_pairs"] = [primers]

    db_key = get(entry, "taxonomy_db", "pr2")
    base["dada2"]["taxonomy"]["database"] = db_key

    # Force fine-grained annotation for accuracy measurement; species level is
    # the ceiling defined in funcdb's RANK_HIERARCHY.
    base["annotation"]["max_rank"] = "species"

    mkpath(CONFIGS_DIR)
    out_path = joinpath(CONFIGS_DIR, "$(key).yml")
    YAML.write_file(out_path, base)
    return out_path
end

# Verify that the FASTQ pair for a dataset exists; the runner refuses to invoke
# the pipeline on missing inputs rather than producing a confusing R-level error.
function _inputs_ready(key::AbstractString)::Bool
    dir = joinpath(DATA_DIR, key)
    isdir(dir) || return false
    has_r1 = any(f -> occursin("_R1", f) && endswith(f, ".fastq.gz"), readdir(dir))
    has_r2 = any(f -> occursin("_R2", f) && endswith(f, ".fastq.gz"), readdir(dir))
    return has_r1 && has_r2
end

# Run the pipeline against one dataset; returns a NamedTuple capturing the run.
function _run_one(key::AbstractString, entry::Dict)
    @info "Layer 1 run starting" key

    if !_inputs_ready(key)
        @warn "Inputs missing; skipping" key dir=joinpath(DATA_DIR, key)
        return (; key, status="skipped_no_inputs")
    end

    config_path    = _write_config(key, entry)
    input_dir      = joinpath(DATA_DIR, key)
    workspace_root = joinpath(OUTPUTS_DIR, key)
    mkpath(workspace_root)

    taxonomy_db = get(entry, "taxonomy_db", "pr2")

    t0 = time()
    try
        dada2(config_path; input_dir=input_dir, workspace_root=workspace_root, taxonomy_db=taxonomy_db)
    catch e
        @error "Pipeline failed" key exception=(e, catch_backtrace())
        return (; key, status="failed", elapsed=time()-t0)
    end
    elapsed = time() - t0

    tax_counts = joinpath(workspace_root, "Tables", "tax_counts.csv")
    isfile(tax_counts) ||
        return (; key, status="failed_no_output", elapsed)

    return (; key, status="ok", elapsed,
              config=config_path, workspace=workspace_root, tax_counts)
end

function main(args::Vector{String}=String[])
    isfile(REGISTRY) || error("Registry not found: $REGISTRY")
    cfg = YAML.load_file(REGISTRY)
    datasets = get(cfg, "datasets", Dict())

    selection = isempty(args) ? collect(keys(datasets)) : args
    runs = NamedTuple[]
    for key in selection
        haskey(datasets, key) || (@warn "Unknown key" key; continue)
        push!(runs, _run_one(key, datasets[key]))
    end

    mkpath(RESULTS_DIR)
    summary = Dict("runs" => [Dict(string(k) => v for (k, v) in pairs(r)) for r in runs])
    YAML.write_file(joinpath(RESULTS_DIR, "runs.yml"), summary)

    @info "Layer 1 runs complete" n=length(runs)
    return runs
end

abspath(PROGRAM_FILE) == @__FILE__ && main(ARGS)
