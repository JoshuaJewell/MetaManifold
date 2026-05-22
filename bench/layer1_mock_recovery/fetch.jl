#!/usr/bin/env julia
# Fetch FASTQ inputs and expected-taxonomy ground truth for Layer 1 datasets.
#
# Reads datasets.yml; for any entry whose URL fields are populated, downloads
# into data/<key>/ and expected/<key>_L6.tsv respectively. Entries with blank
# URLs are skipped with a warning so the script remains idempotent during
# the period in which a user is populating the registry incrementally.
#
# Usage:
#   julia --project=. bench/layer1_mock_recovery/fetch.jl
#
# Local paths in expected_l6 are honoured directly (copied into expected/).

using YAML, Downloads, Logging

const BENCH_DIR = @__DIR__
const REGISTRY  = joinpath(BENCH_DIR, "datasets.yml")
const DATA_DIR     = joinpath(BENCH_DIR, "data")
const EXPECTED_DIR = joinpath(BENCH_DIR, "expected")

# Robust download wrapper. Returns true on success, false on any failure.
function _try_download(url::AbstractString, dest::AbstractString)::Bool
    try
        mkpath(dirname(dest))
        Downloads.download(url, dest)
        return true
    catch e
        @warn "Download failed" url dest exception=(e, catch_backtrace())
        return false
    end
end

# Resolve an expected_l6 spec, which may be a URL or a local absolute path.
function _resolve_expected(spec::AbstractString, key::AbstractString)
    isempty(spec) && return nothing
    dest = joinpath(EXPECTED_DIR, "$(key)_L6.tsv")
    if startswith(spec, "http://") || startswith(spec, "https://")
        return _try_download(spec, dest) ? dest : nothing
    end
    # Local path: copy into expected/ so the benchmark is self-contained.
    isfile(spec) || (@warn "Expected file missing" key spec; return nothing)
    mkpath(EXPECTED_DIR)
    cp(spec, dest; force=true)
    return dest
end

function main()
    isfile(REGISTRY) || error("Registry not found: $REGISTRY")
    cfg = YAML.load_file(REGISTRY)
    datasets = get(cfg, "datasets", Dict())
    isempty(datasets) && (@warn "No datasets in registry"; return)

    mkpath(DATA_DIR); mkpath(EXPECTED_DIR)

    for (key, entry) in datasets
        @info "Processing dataset" key
        target_dir = joinpath(DATA_DIR, key)

        fwd_url = get(entry, "fastq_forward", "")
        rev_url = get(entry, "fastq_reverse", "")
        exp_url = get(entry, "expected_l6", "")

        if isempty(fwd_url) || isempty(rev_url)
            @warn "Skipping FASTQ download; URL fields blank" key
        else
            _try_download(fwd_url, joinpath(target_dir, "$(key)_R1.fastq.gz"))
            _try_download(rev_url, joinpath(target_dir, "$(key)_R2.fastq.gz"))
        end

        _resolve_expected(exp_url, key)
    end

    @info "Fetch complete" data=DATA_DIR expected=EXPECTED_DIR
end

abspath(PROGRAM_FILE) == @__FILE__ && main()
