#!/usr/bin/env julia
# Render results/metrics.yml as a compact markdown report at results/report.md.
# The summary table is one row per dataset; a per-sample appendix follows for
# datasets with more than one shared sample. The report is regenerated wholesale
# on each run and is safe to commit as a benchmark artefact.
#
# Usage:
#   julia --project=. bench/layer1_mock_recovery/report.jl

using YAML, Printf, Dates

const BENCH_DIR   = @__DIR__
const RESULTS_DIR = joinpath(BENCH_DIR, "results")

_fmt(x) = (x isa Real && isnan(x)) ? "n/a" : (x isa Real ? @sprintf("%.3f", x) : string(x))

function main()
    metrics_yml = joinpath(RESULTS_DIR, "metrics.yml")
    isfile(metrics_yml) || error("metrics.yml not found; run evaluate.jl first")
    datasets = get(YAML.load_file(metrics_yml), "datasets", Dict[])

    io = IOBuffer()
    println(io, "# Layer 1: mock-community recovery")
    println(io)
    println(io, "Generated ", Dates.format(now(), "yyyy-mm-dd HH:MM"), ".")
    println(io)
    println(io, "Lower Bray-Curtis is better (0 = identical composition); higher F1 is better.")
    println(io)
    println(io, "| Dataset | Samples | Mean Bray-Curtis | Mean genus F1 |")
    println(io, "|---|---:|---:|---:|")
    for d in datasets
        @printf(io, "| %s | %d | %s | %s |\n",
                get(d, "key", "?"),
                get(d, "n_samples", 0),
                _fmt(get(d, "bray_curtis_mean", NaN)),
                _fmt(get(d, "f1_mean", NaN)))
    end
    println(io)

    for d in datasets
        per = get(d, "per_sample", Dict[])
        length(per) > 1 || continue
        println(io, "## ", get(d, "key", "?"))
        println(io)
        println(io, "| Sample | Bray-Curtis | Precision | Recall | F1 |")
        println(io, "|---|---:|---:|---:|---:|")
        for s in per
            @printf(io, "| %s | %s | %s | %s | %s |\n",
                    get(s, "sample", "?"),
                    _fmt(get(s, "bray_curtis", NaN)),
                    _fmt(get(s, "precision", NaN)),
                    _fmt(get(s, "recall", NaN)),
                    _fmt(get(s, "f1", NaN)))
        end
        println(io)
    end

    out_path = joinpath(RESULTS_DIR, "report.md")
    write(out_path, String(take!(io)))
    @info "Report written" out_path
end

abspath(PROGRAM_FILE) == @__FILE__ && main()
