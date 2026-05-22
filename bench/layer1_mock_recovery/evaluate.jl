#!/usr/bin/env julia
# Compare predicted L6 (genus-level) taxa tables produced by the runner to
# the expected ground truth recorded in expected/. For each dataset the
# evaluator computes, per shared sample:
#
#   - Bray-Curtis dissimilarity between predicted and expected proportions
#   - Genus-level presence/absence F1 (precision, recall, F1)
#
# Results are written to results/metrics.yml for the report generator to consume.
#
# Usage:
#   julia --project=. bench/layer1_mock_recovery/evaluate.jl
#
# Sample alignment is the most fragile step. The evaluator matches on exact
# sample-name equality between the predicted count-column headers and the
# expected file's header row; mismatches are logged so a per-dataset alias
# table can be added later without changing the evaluator's structure.

using YAML, CSV, DataFrames, Logging, Statistics

const BENCH_DIR    = @__DIR__
const REGISTRY     = joinpath(BENCH_DIR, "datasets.yml")
const EXPECTED_DIR = joinpath(BENCH_DIR, "expected")
const RESULTS_DIR  = joinpath(BENCH_DIR, "results")

## Taxonomy formatting
# Canonical L6 rank order. PR2 and SILVA differ in their finer ranks, but the
# six-level QIIME L6 string is what the supplemental and mockrobiota expected
# files use, so the evaluator forces both predicted and expected into the same
# semicolon-joined form before comparing.
const L6_RANKS_SILVA = ["Kingdom", "Phylum", "Class", "Order", "Family", "Genus"]
const L6_RANKS_PR2   = ["Domain",  "Supergroup", "Division", "Class", "Order", "Family", "Genus"]
const L6_PREFIXES = ["k__", "p__", "c__", "o__", "f__", "g__"]

# Pick rank columns from a DataFrame, preferring DADA2-suffixed when present.
function _rank_columns(df::DataFrame, ranks::Vector{String})::Vector{String}
    chosen = String[]
    for r in ranks
        d2 = r * "_dada2"
        if d2 in names(df); push!(chosen, d2)
        elseif r in names(df); push!(chosen, r)
        else; push!(chosen, "")
        end
    end
    chosen
end

# Build a QIIME-style L6 string from a row of taxonomic rank values.
function _l6_string(vals::Vector)::String
    parts = String[]
    # If more than six ranks (PR2), drop the intermediate ones to align to L6.
    # We keep the conventional Kingdom-Phylum-Class-Order-Family-Genus slots
    # using the first six non-empty entries from the right (coarsest to finest).
    finest_six = vals[max(1, length(vals)-5):end]
    for (i, v) in enumerate(finest_six)
        s = (ismissing(v) || isnothing(v)) ? "" : strip(string(v))
        push!(parts, L6_PREFIXES[i] * s)
    end
    join(parts, ";")
end

## Loading
# Parse the QIIME L6 expected file. The first column is the taxon string, the
# remainder are per-sample relative abundances. Lines beginning with '#' that
# are not the header line are skipped; the header line is the one whose first
# token is '#OTU ID' or 'Taxon'.
function _load_expected(path::AbstractString)::DataFrame
    isfile(path) || error("Expected file missing: $path")
    lines = readlines(path)
    header_idx = findfirst(l -> startswith(l, "#OTU ID") || startswith(l, "Taxon") || startswith(l, "#Taxon"), lines)
    isnothing(header_idx) && error("No header row in $path")
    header = split(strip(lines[header_idx]), '\t')
    header[1] = "taxon"
    body = lines[header_idx+1:end]
    io = IOBuffer(join([join(header, '\t')], "\n") * "\n" * join(body, "\n"))
    return CSV.read(io, DataFrame; delim='\t')
end

# Detect sample-count columns in a predicted tax_counts.csv. Sample columns are
# integer-typed and exclude *_boot and any rank-bearing columns. This mirrors
# the heuristic used by FuncDBAnnotation._sample_count_cols.
function _predicted_samples(df::DataFrame)::Vector{String}
    out = String[]
    for col in names(df)
        endswith(col, "_boot") && continue
        T = nonmissingtype(eltype(df[!, col]))
        T <: Integer && push!(out, col)
    end
    out
end

## Metrics
# Bray-Curtis dissimilarity between two abundance vectors aligned on the union
# of taxa. Returns NaN when both vectors sum to zero.
function _bray_curtis(a::AbstractDict{String,Float64}, b::AbstractDict{String,Float64})::Float64
    keys_all = union(keys(a), keys(b))
    num = 0.0; den = 0.0
    for k in keys_all
        x = get(a, k, 0.0); y = get(b, k, 0.0)
        num += abs(x - y); den += x + y
    end
    den == 0 ? NaN : num / den
end

# Presence/absence F1 at the L6 string set.
function _f1(predicted::Set{String}, expected::Set{String})
    tp = length(intersect(predicted, expected))
    fp = length(setdiff(predicted, expected))
    fn = length(setdiff(expected, predicted))
    prec = tp + fp == 0 ? 0.0 : tp / (tp + fp)
    rec  = tp + fn == 0 ? 0.0 : tp / (tp + fn)
    f1   = prec + rec == 0 ? 0.0 : 2 * prec * rec / (prec + rec)
    (precision=prec, recall=rec, f1=f1)
end

## Per-dataset evaluation
function _evaluate_one(key::AbstractString, entry::Dict, tax_counts_path::AbstractString)
    @info "Evaluating" key
    expected_path = joinpath(EXPECTED_DIR, "$(key)_L6.tsv")
    isfile(expected_path) || (@warn "No expected file; skipping" key; return nothing)

    predicted = CSV.read(tax_counts_path, DataFrame; stringtype=String)
    expected  = _load_expected(expected_path)

    db = lowercase(get(entry, "taxonomy_db", "pr2"))
    rank_order = db == "pr2" ? L6_RANKS_PR2 : L6_RANKS_SILVA
    rank_cols  = _rank_columns(predicted, rank_order)
    any(isempty, rank_cols) && (@warn "Missing rank columns" key rank_cols; return nothing)

    # Build per-row L6 strings on the predicted side.
    pred_l6 = [_l6_string([row[c] for c in rank_cols]) for row in eachrow(predicted)]
    predicted[!, :l6] = pred_l6

    pred_samples = _predicted_samples(predicted)
    exp_samples  = [c for c in names(expected) if c != "taxon"]
    shared = intersect(pred_samples, exp_samples)
    isempty(shared) && (@warn "No shared samples" key pred=pred_samples exp=exp_samples; return nothing)

    per_sample = Dict{String,Any}[]
    for s in shared
        # Predicted relative abundance at L6.
        agg_p = Dict{String,Float64}()
        for r in eachrow(predicted)
            count = r[s]; count === missing && continue
            agg_p[r.l6] = get(agg_p, r.l6, 0.0) + Float64(count)
        end
        total_p = sum(values(agg_p))
        total_p > 0 && (for k in keys(agg_p); agg_p[k] /= total_p; end)

        agg_e = Dict{String,Float64}()
        for r in eachrow(expected)
            v = r[s]; v === missing && continue
            agg_e[String(r.taxon)] = get(agg_e, String(r.taxon), 0.0) + Float64(v)
        end

        bc = _bray_curtis(agg_p, agg_e)
        f  = _f1(Set(keys(agg_p)), Set(keys(agg_e)))
        push!(per_sample, Dict("sample" => s, "bray_curtis" => bc,
                                "precision" => f.precision, "recall" => f.recall, "f1" => f.f1))
    end

    bc_vals = [Float64(x["bray_curtis"]) for x in per_sample if !isnan(x["bray_curtis"])]
    f1_vals = [Float64(x["f1"]) for x in per_sample]

    return Dict(
        "key" => key,
        "n_samples" => length(per_sample),
        "bray_curtis_mean" => isempty(bc_vals) ? NaN : mean(bc_vals),
        "f1_mean" => isempty(f1_vals) ? NaN : mean(f1_vals),
        "per_sample" => per_sample,
    )
end

function main()
    isfile(REGISTRY) || error("Registry not found: $REGISTRY")
    cfg = YAML.load_file(REGISTRY)
    datasets = get(cfg, "datasets", Dict())

    runs_yml = joinpath(RESULTS_DIR, "runs.yml")
    isfile(runs_yml) || error("runs.yml not found; run runner.jl first")
    runs = get(YAML.load_file(runs_yml), "runs", Dict[])

    metrics = Dict[]
    for r in runs
        key = get(r, "key", "")
        if get(r, "status", "") != "ok"
            @warn "Skipping non-ok run" key status=get(r, "status", "")
            continue
        end
        haskey(datasets, key) || continue
        tax_counts = get(r, "tax_counts", "")
        isfile(tax_counts) || (@warn "tax_counts.csv missing" key tax_counts; continue)
        m = _evaluate_one(key, datasets[key], tax_counts)
        isnothing(m) || push!(metrics, m)
    end

    mkpath(RESULTS_DIR)
    YAML.write_file(joinpath(RESULTS_DIR, "metrics.yml"), Dict("datasets" => metrics))
    @info "Evaluation complete" n=length(metrics)
    return metrics
end

abspath(PROGRAM_FILE) == @__FILE__ && main()
