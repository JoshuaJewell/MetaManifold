module Analysis

# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

using DataFrames, JSON3, DuckDB, DBInterface, RCall
using ..DiversityMetrics: richness, shannon, simpson, normalise_counts,
                          auto_min_depth

export sample_columns, filtered_counts, filtered_df, taxonomy_levels, taxon_column,
       aggregate_by_taxon, combined_counts_across_runs, combined_asv_counts_across_runs,
       sequence_column_name, pool_columns,
       alpha_chart, taxa_bar_chart, pipeline_stats_chart,
       alpha_boxplot, nmds_chart,
       run_nmds, run_permanova, r_available,
       venn_taxa_present

## DuckDB query helpers for analysis
"""
    sample_columns(con, table) -> Vector{String}

Identify per-sample count columns in a DuckDB table.
Returns all numeric columns except known non-count names.
"""
function sample_columns(con, table::String)
    result = DataFrame(DBInterface.execute(con,
        "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = ?", [table]))
    non_count = Set([
        "SeqName", "Pident", "Accession", "rRNA", "Organellum", "specimen",
        "sequence", "OTU", "ASV",
        "Domain", "Supergroup", "Division", "Subdivision",
        "Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species",
        "consensus_score", "total",
    ])
    numeric_types = Set(["BIGINT", "INTEGER", "DOUBLE", "FLOAT", "HUGEINT", "SMALLINT", "TINYINT"])
    cols = String[]
    for row in eachrow(result)
        col = string(row.column_name)
        dtype = string(row.data_type)
        col in non_count && continue
        endswith(col, "_dada2") && continue
        endswith(col, "_boot") && continue
        endswith(col, "_vsearch") && continue
        startswith(col, "total_") && continue
        dtype in numeric_types || continue
        push!(cols, col)
    end
    cols
end

"""
    sequence_column_name(columns) -> Union{String, Nothing}

Resolve the DNA sequence column name from a table schema. Some imported CSVs
preserve the original DADA2 `Sequence` header while later pipeline stages use
lowercase `sequence`.
"""
function sequence_column_name(columns)::Union{String,Nothing}
    for col in columns
        lowercase(col) == "sequence" && return col
    end
    nothing
end

"""
    taxonomy_levels(con, table) -> Vector{String}

Detect which taxonomy rank columns exist in the table, returning canonical rank names
(without suffix). Recognises both plain names (VSEARCH: "Genus") and DADA2-suffixed
names ("Genus_dada2"), so the same rank list is returned for either annotation source.
"""
function taxonomy_levels(con, table::String)
    result = DataFrame(DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_name = ?", [table]))
    existing = Set(string.(result.column_name))
    known_ranks = [
        "Domain", "Supergroup", "Division", "Subdivision",
        "Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species",
    ]
    filter(r -> r in existing || (r * "_dada2") in existing, known_ranks)
end

"""
    taxon_column(columns, rank) -> String

Resolve a canonical rank name (e.g. "Genus") to the actual column name present in
the table. Checks for the plain name first (VSEARCH), then the DADA2-suffixed variant.
Falls back to the plain name if neither is found (SQL will error explicitly).
"""
function taxon_column(columns::Union{Vector{String}, AbstractSet{String}}, rank::String)
    col_set = columns isa AbstractSet ? columns : Set(columns)
    rank in col_set && return rank
    dada2 = rank * "_dada2"
    dada2 in col_set && return dada2
    rank
end

"""
    filtered_counts(con, table, sample_cols, where_clause, where_params) -> Matrix{Float64}

Return a samples-by-features count matrix from DuckDB with filters applied.
Rows = samples, columns = ASV/OTU rows matching the filter.
"""
function filtered_counts(con, table::String, sample_cols::Vector{String},
                         where_clause::String, where_params::Vector)
    col_sql = join(["\"$c\"" for c in sample_cols], ", ")
    sql = "SELECT $col_sql FROM \"$table\" $where_clause"
    result = DataFrame(DBInterface.execute(con, sql, where_params))
    nrow(result) == 0 && return zeros(Float64, length(sample_cols), 0)
    n_features = nrow(result)
    n_samples = length(sample_cols)
    mat = zeros(Float64, n_samples, n_features)
    for (j, row) in enumerate(eachrow(result))
        for (i, col) in enumerate(sample_cols)
            v = row[Symbol(col)]
            mat[i, j] = ismissing(v) ? 0.0 : Float64(v)
        end
    end
    mat
end

"""
    filtered_df(con, table, where_clause, where_params) -> DataFrame

Return the full filtered table as a DataFrame.
"""
function filtered_df(con, table::String,
                     where_clause::String, where_params::Vector)
    sql = "SELECT * FROM \"$table\" $where_clause"
    DataFrame(DBInterface.execute(con, sql, where_params))
end

"""
    aggregate_by_taxon(con, table, sample_cols, rank, where_clause, where_params) -> DataFrame

Group rows by a taxonomy rank, summing sample counts.
"""
function aggregate_by_taxon(con, table::String, sample_cols::Vector{String},
                            rank::String, where_clause::String, where_params::Vector)
    sum_exprs = join(["SUM(COALESCE(\"$c\", 0)) AS \"$c\"" for c in sample_cols], ", ")
    sql = """
        SELECT COALESCE(NULLIF(TRIM("$rank"), ''), 'Unclassified') AS taxon, $sum_exprs
        FROM "$table" $where_clause
        GROUP BY taxon
        ORDER BY ($(join(["SUM(COALESCE(\"$c\", 0))" for c in sample_cols], " + "))) DESC
    """
    DataFrame(DBInterface.execute(con, sql, where_params))
end

"""
    venn_taxa_present(con, table, sample_cols, rank_col, where_clause, where_params) -> Vector{String}

Return sorted taxon names at `rank_col` that have at least one read
summed across `sample_cols` after applying the given WHERE clause.
Null/blank/whitespace-only taxon values are coalesced to "Unclassified".
Returns an empty vector if `sample_cols` is empty.
"""
function venn_taxa_present(con, table::String, sample_cols::Vector{String},
                           rank_col::String, where_clause::String,
                           where_params::Vector)::Vector{String}
    isempty(sample_cols) && return String[]
    reads_expr = join(["SUM(COALESCE(\"$c\", 0))" for c in sample_cols], " + ")
    sql = """
        SELECT COALESCE(NULLIF(TRIM("$rank_col"), ''), 'Unclassified') AS taxon
        FROM "$table"
        $where_clause
        GROUP BY taxon
        HAVING ($reads_expr) > 0
        ORDER BY taxon
    """
    df = DataFrame(DBInterface.execute(con, sql, where_params))
    nrow(df) == 0 && return String[]
    String.(df.taxon)
end

"""
    combined_counts_across_runs(run_data) -> (Matrix{Float64}, Vector{String}, Vector{String}, Vector{String})

Build a combined taxonomy-aggregated count matrix across multiple runs for NMDS/PERMANOVA.
`run_data` is a vector of `(label, sample_cols, taxon_counts_df)` tuples.

Returns (matrix, all_sample_names, taxon_labels, run_labels_per_sample).
"""
function combined_counts_across_runs(
    run_data::Vector{Tuple{String, Vector{String}, DataFrame}}
)
    taxa_counts = Dict{String, Dict{String, Float64}}()
    all_samples = String[]
    run_labels = String[]

    for (label, sample_cols, df) in run_data
        append!(all_samples, sample_cols)
        append!(run_labels, fill(label, length(sample_cols)))
        for row in eachrow(df)
            taxon = string(row.taxon)
            td = get!(taxa_counts, taxon, Dict{String, Float64}())
            for col in sample_cols
                v = row[Symbol(col)]
                td[col] = get(td, col, 0.0) + (ismissing(v) ? 0.0 : Float64(v))
            end
        end
    end

    taxa_labels = sort(collect(keys(taxa_counts)))
    n_samples = length(all_samples)
    n_taxa = length(taxa_labels)
    mat = zeros(Float64, n_samples, n_taxa)

    for (j, taxon) in enumerate(taxa_labels)
        td = taxa_counts[taxon]
        for (i, sample) in enumerate(all_samples)
            mat[i, j] = get(td, sample, 0.0)
        end
    end

    mat, all_samples, taxa_labels, run_labels
end

"""
    combined_asv_counts_across_runs(run_data) -> (Matrix{Float64}, Vector{String}, Vector{String}, Vector{String})

Build a combined ASV count matrix across multiple runs using the raw DNA sequence
string as the alignment key, so identical sequences from different runs collapse
into the same column.

`run_data` is a vector of `(label, sample_cols, asv_counts_df)` tuples where
`asv_counts_df` must contain a `sequence` column.

Returns (matrix, all_sample_names, sequence_labels, run_labels_per_sample).
"""
function combined_asv_counts_across_runs(
    run_data::Vector{Tuple{String, Vector{String}, DataFrame}}
)
    seq_counts = Dict{String, Dict{String, Float64}}()
    all_samples = String[]
    run_labels = String[]

    for (label, sample_cols, df) in run_data
        append!(all_samples, sample_cols)
        append!(run_labels, fill(label, length(sample_cols)))
        for row in eachrow(df)
            seq = string(row[:sequence])
            sd = get!(seq_counts, seq, Dict{String, Float64}())
            for col in sample_cols
                v = row[Symbol(col)]
                sd[col] = get(sd, col, 0.0) + (ismissing(v) ? 0.0 : Float64(v))
            end
        end
    end

    seq_labels = sort(collect(keys(seq_counts)))
    n_samples = length(all_samples)
    n_seqs = length(seq_labels)
    mat = zeros(Float64, n_samples, n_seqs)

    for (j, seq) in enumerate(seq_labels)
        sd = seq_counts[seq]
        for (i, sample) in enumerate(all_samples)
            mat[i, j] = get(sd, sample, 0.0)
        end
    end

    mat, all_samples, seq_labels, run_labels
end

## Plotly chart builders
# All functions return a Dict suitable for JSON3.write -> Plotly JSON.
## Colour palette
function _palette_hex(n::Int)::Vector{String}
    base = ["#E69F00", "#56B4E9", "#009E73", "#F0E442",
            "#0072B2", "#D55E00", "#CC79A7"]
    n <= length(base) && return base[1:n]
    colours = copy(base)
    for i in (length(base) + 1):n
        hue = mod(i * 137.508, 360.0)
        c = 0.85 * 0.65
        x = c * (1.0 - abs(mod(hue / 60.0, 2.0) - 1.0))
        m = 0.85 - c
        r, g, b = hue < 60  ? (c + m, x + m, m) :
                hue < 120 ? (x + m, c + m, m) :
                hue < 180 ? (m, c + m, x + m) :
                hue < 240 ? (m, x + m, c + m) :
                hue < 300 ? (x + m, m, c + m) :
                            (c + m, m, x + m)
        hex(v) = lpad(string(round(Int, v * 255), base=16), 2, '0')
        push!(colours, "#" * hex(r) * hex(g) * hex(b))
    end
    colours[1:n]
end

const _GREY_HEX = "#B3B3B3"

function _apply_grey!(colours::Vector{String}, labels::Vector{String})
    for (i, l) in enumerate(labels)
        l in ("Unclassified", "Other") && (colours[i] = _GREY_HEX)
    end
end

## Alpha diversity chart
"""
    alpha_chart(sample_names, richness, shannon, simpson) -> Dict

Three-panel bar chart of alpha diversity metrics per sample.
"""
function alpha_chart(sample_names::Vector{String},
                     richness_values::Vector{Int},
                     shannon_values::Vector{Float64},
                     simpson_values::Vector{Float64})
    colour = _palette_hex(1)[1]
    metrics = [
        ("y",  "x",  "Richness (observed ASVs)", Float64.(richness_values)),
        ("y2", "x2", "Shannon index",            shannon_values),
        ("y3", "x3", "Gini-Simpson (1 - D)",       simpson_values),
    ]
    traces = [Dict{String,Any}(
        "type" => "bar", "x" => sample_names, "y" => vals,
        "xaxis" => xax, "yaxis" => yax,
        "showlegend" => false, "marker" => Dict("color" => colour),
    ) for (yax, xax, _, vals) in metrics]

    layout = Dict{String,Any}(
        "title" => Dict("text" => "Alpha diversity"),
        "grid" => Dict("rows" => 3, "columns" => 1, "pattern" => "independent"),
        "yaxis"  => Dict("title" => "Richness (observed ASVs)"),
        "yaxis2" => Dict("title" => "Shannon index"),
        "yaxis3" => Dict("title" => "Gini-Simpson (1 - D)"),
        "xaxis"  => Dict("tickangle" => -45),
        "xaxis2" => Dict("tickangle" => -45),
        "xaxis3" => Dict("title" => "Sample", "tickangle" => -45),
    )
    Dict("data" => traces, "layout" => layout)
end

## Column pooling
"""
    pool_columns(sample_names, counts, groups) -> (Vector{String}, Matrix{Float64})

Pool (sum) sample columns into summary columns by group prefix.

Each group label in `groups` is matched against sample names via
`startswith(name, group * "_")`.  Columns matching the same group are summed.
Any unmatched columns are summed into an `"Other"` group.

When `groups` is empty, all columns are summed into a single column named
`fallback_label` (defaults to `"Total"`).

`counts` is taxa-by-samples; the returned matrix has one column per group.
"""
function pool_columns(sample_names::Vector{String}, counts::Matrix{Float64},
                      groups::Vector{String}; fallback_label::String="Total")
    if isempty(groups)
        return ([fallback_label], reshape(vec(sum(counts, dims=2)), :, 1))
    end

    pooled_names = String[]
    pooled_cols  = Vector{Float64}[]
    matched      = falses(length(sample_names))

    for grp in groups
        pfx  = grp * "_"
        mask = [startswith(s, pfx) for s in sample_names]
        any(mask) || continue
        matched .|= mask
        push!(pooled_cols, vec(sum(counts[:, mask], dims=2)))
        push!(pooled_names, grp)
    end

    if any(.!matched)
        push!(pooled_cols, vec(sum(counts[:, .!matched], dims=2)))
        push!(pooled_names, "Other")
    end

    isempty(pooled_cols) && return ([fallback_label], reshape(vec(sum(counts, dims=2)), :, 1))
    (pooled_names, reduce(hcat, pooled_cols))
end

## Taxa bar chart
"""
    taxa_bar_chart(taxon_labels, sample_names, counts; top_n, relative) -> Dict

Stacked bar chart of taxonomic composition.
`counts` is a taxa-by-samples matrix (from aggregate_by_taxon output).
"""
function taxa_bar_chart(taxon_labels::Vector{String},
                        sample_names::Vector{String},
                        counts::Matrix{Float64};
                        top_n::Int=15, relative::Bool=true)
    n_taxa = length(taxon_labels)

    # Drop samples (columns) that contain no data before plotting.
    col_totals = vec(sum(counts, dims=1))
    empty_mask = col_totals .== 0
    if any(empty_mask)
        dropped = sample_names[empty_mask]
        @info "Taxa bar: dropping $(length(dropped)) empty sample column(s)" samples=dropped
        keep_cols = .!empty_mask
        counts = counts[:, keep_cols]
        sample_names = sample_names[keep_cols]
    end
    n_samples = length(sample_names)

    totals = vec(sum(counts, dims=2))
    order = sortperm(totals, rev=true)

    if n_taxa > top_n
        keep = order[1:top_n]
        other = vec(sum(counts[order[(top_n+1):end], :], dims=1))
        counts = vcat(counts[keep, :], other')
        final_labels = vcat(taxon_labels[keep], ["Other"])
    else
        counts = counts[order, :]
        final_labels = taxon_labels[order]
    end

    if relative
        col_sums = vec(sum(counts, dims=1))
        for j in 1:n_samples
            col_sums[j] > 0 && (counts[:, j] ./= col_sums[j])
        end
    end

    n_final = length(final_labels)
    colours = _palette_hex(n_final)
    _apply_grey!(colours, final_labels)
    ylabel = relative ? "Relative abundance" : "Read count"
    title = relative ? "Taxonomic composition" : "Taxonomic composition (absolute)"

    traces = [Dict{String,Any}(
        "type" => "bar", "name" => final_labels[i],
        "x" => sample_names, "y" => collect(counts[i, :]),
        "marker" => Dict("color" => colours[i]),
    ) for i in 1:n_final]

    layout = Dict{String,Any}(
        "barmode" => "stack",
        "title" => Dict("text" => title),
        "xaxis" => Dict("title" => "Sample", "tickangle" => -45),
        "yaxis" => Dict{String,Any}("title" => ylabel),
        "legend" => Dict("traceorder" => "normal"),
    )
    relative && (layout["yaxis"]["range"] = [0, 1])
    Dict("data" => traces, "layout" => layout)
end

## Pipeline stats chart
const _STAGE_ORDER = ["input", "filtered", "denoisedF", "denoisedR", "merged", "nochim"]
const _STAGE_LABELS = Dict(
    "input" => "Input", "filtered" => "Filtered",
    "denoisedF" => "Denoised (F)", "denoisedR" => "Denoised (R)",
    "merged" => "Merged", "nochim" => "Chimera-free",
)

"""
    pipeline_stats_chart(stats_df) -> Dict

Grouped bar chart of read counts at each DADA2 pipeline stage.
`stats_df` must have a `sample` column plus stage count columns.
"""
function pipeline_stats_chart(stats_df::DataFrame)
    all_cols = names(stats_df)
    stage_cols = [c for c in _STAGE_ORDER if c in all_cols]
    reads_cols = sort([c for c in all_cols if startswith(c, "reads_")])
    append!(stage_cols, reads_cols)
    isempty(stage_cols) && return nothing

    sample_names = String.(stats_df.sample)
    stage_labels = [get(_STAGE_LABELS, c, c) for c in stage_cols]
    colours = _palette_hex(length(sample_names))

    traces = [Dict{String,Any}(
        "type" => "bar", "name" => sample_names[si],
        "x" => stage_labels,
        "y" => [let v = stats_df[si, Symbol(c)]; ismissing(v) ? 0.0 : Float64(v) end
                for c in stage_cols],
        "marker" => Dict("color" => colours[si]),
    ) for si in eachindex(sample_names)]

    layout = Dict{String,Any}(
        "barmode" => "group",
        "title" => Dict("text" => "Reads through pipeline stages"),
        "xaxis" => Dict("title" => "Pipeline stage", "tickangle" => -45),
        "yaxis" => Dict("title" => "Read count"),
    )
    Dict("data" => traces, "layout" => layout)
end

## Alpha diversity boxplot (cross-run)
"""
    alpha_boxplot(groups) -> Dict

Three-panel boxplot comparing alpha diversity across groups.
`groups` is a vector of `(label, richness, shannon, simpson)` tuples.
"""
function _significance_stars(p::Union{Float64,Nothing})
    isnothing(p) && return "n/a"
    isnan(p) && return "n/a"
    p <= 0.001 && return "***"
    p <= 0.01  && return "**"
    p <= 0.05  && return "*"
    return "ns"
end

function _format_p_value(p::Union{Float64,Nothing})
    isnothing(p) && return "p = n/a"
    isnan(p) && return "p = n/a"
    p < 0.001 && return "p < 0.001"
    "p = $(round(p; digits=3))"
end

function _hex_to_rgba(hex::String, alpha::Float64)::String
    length(hex) == 7 || return hex
    r = parse(Int, hex[2:3]; base=16)
    g = parse(Int, hex[4:5]; base=16)
    b = parse(Int, hex[6:7]; base=16)
    "rgba($r,$g,$b,$alpha)"
end

function _paired_metric_map(sample_ids::Vector{String}, values::Vector{Float64})
    buckets = Dict{String, Vector{Float64}}()
    for (sid, value) in zip(sample_ids, values)
        push!(get!(buckets, sid, Float64[]), value)
    end
    Dict(k => sum(v) / length(v) for (k, v) in buckets)
end

function _alpha_significance(values::Vector{Float64},
                             labels::Vector{String},
                             sample_ids::Vector{String};
                             pairwise::Bool=false,
                             paired_samples::Bool=false)
    _ensure_r() || return nothing, DataFrame(group1=String[], group2=String[], p=Float64[])
    lock(_r_lock) do
        if paired_samples
            groups_u = unique(labels)
            paired_maps = Dict(label => _paired_metric_map(
                [sample_ids[i] for i in eachindex(labels) if labels[i] == label],
                [values[i] for i in eachindex(labels) if labels[i] == label],
            ) for label in groups_u)
            common_ids = reduce(intersect, [Set(keys(m)) for m in Base.values(paired_maps)])
            isempty(common_ids) && return nothing, DataFrame(group1=String[], group2=String[], p=Float64[])
            common = sort(collect(common_ids))

            RCall.globalEnv[:paired_groups] = groups_u
            RCall.globalEnv[:paired_mat] = hcat([
                [paired_maps[label][sid] for sid in common] for label in groups_u
            ]...)
            RCall.globalEnv[:do_pairwise] = pairwise
            RCall.reval("""
                overall_p <- tryCatch({
                    if (ncol(paired_mat) == 2) {
                        wilcox.test(paired_mat[,1], paired_mat[,2], paired = TRUE, exact = FALSE)\$p.value
                    } else {
                        suppressWarnings(friedman.test(paired_mat)\$p.value)
                    }
                }, error = function(e) NA_real_)
                pairwise_df <- data.frame(group1=character(), group2=character(), p=double(),
                                          stringsAsFactors=FALSE)
                if (do_pairwise && ncol(paired_mat) >= 2) {
                    rows <- list()
                    pvals <- c()
                    for (i in seq_len(ncol(paired_mat) - 1)) {
                        for (j in (i + 1):ncol(paired_mat)) {
                            p <- tryCatch(
                                wilcox.test(paired_mat[,i], paired_mat[,j], paired = TRUE, exact = FALSE)\$p.value,
                                error = function(e) NA_real_
                            )
                            rows[[length(rows) + 1]] <- c(as.character(paired_groups[i]), as.character(paired_groups[j]))
                            pvals <- c(pvals, p)
                        }
                    }
                    if (length(rows) > 0) {
                        pairwise_df <- data.frame(
                            group1 = vapply(rows, `[`, character(1), 1),
                            group2 = vapply(rows, `[`, character(1), 2),
                            p = p.adjust(pvals, method = "BH"),
                            stringsAsFactors = FALSE
                        )
                    }
                }
            """)
            p_value = RCall.rcopy(RCall.reval("overall_p"))
            pairwise_df = DataFrame(RCall.rcopy(RCall.reval("pairwise_df")))
            RCall.reval("rm(paired_groups, paired_mat, do_pairwise, overall_p, pairwise_df); gc()")
        else
            RCall.globalEnv[:values] = values
            RCall.globalEnv[:groups] = labels
            RCall.globalEnv[:do_pairwise] = pairwise
            RCall.reval("""
                groups_f <- factor(groups, levels = unique(groups))
                overall_p <- tryCatch(
                    kruskal.test(values ~ groups_f)\$p.value,
                    error = function(e) NA_real_
                )
                pairwise_df <- data.frame(group1=character(), group2=character(), p=double(),
                                          stringsAsFactors=FALSE)
                if (do_pairwise && length(unique(groups_f)) >= 2) {
                    pw <- tryCatch(
                        pairwise.wilcox.test(values, groups_f, p.adjust.method = "BH", exact = FALSE),
                        error = function(e) NULL
                    )
                    if (!is.null(pw) && !is.null(pw\$p.value)) {
                        tbl <- as.data.frame(as.table(pw\$p.value), stringsAsFactors = FALSE)
                        names(tbl) <- c("group1", "group2", "p")
                        pairwise_df <- tbl[!is.na(tbl\$p), , drop = FALSE]
                    }
                }
            """)
            p_value = RCall.rcopy(RCall.reval("overall_p"))
            pairwise_df = DataFrame(RCall.rcopy(RCall.reval("pairwise_df")))
            RCall.reval("rm(values, groups, do_pairwise, groups_f, overall_p, pairwise_df); gc()")
        end
        overall_p = ismissing(p_value) ? nothing : Float64(p_value)
        overall_p, pairwise_df
    end
end

function _add_pairwise_annotations!(layout::Dict{String,Any},
                                    xaxis_key::String,
                                    yaxis_ref::String,
                                    yaxis_layout_key::String,
                                    group_labels::Vector{String},
                                    values_by_label::Dict{String, Vector{Float64}},
                                    pairwise_df::DataFrame)
    nrow(pairwise_df) == 0 && return

    all_vals = reduce(vcat, values(values_by_label); init=Float64[])
    isempty(all_vals) && return
    min_val = minimum(all_vals)
    max_val = maximum(all_vals)
    span = max(max_val - min_val, 1.0)
    step = 0.12 * span
    y = max_val + 0.12 * span

    shapes = get!(layout, "shapes", Any[])
    annotations = get!(layout, "annotations", Any[])
    label_positions = Dict(label => idx for (idx, label) in enumerate(group_labels))
    n_groups = max(length(group_labels), 1)
    for row in eachrow(pairwise_df)
        ismissing(row.p) && continue
        g1 = String(row.group1)
        g2 = String(row.group2)
        g1 in group_labels || continue
        g2 in group_labels || continue
        p = Float64(row.p)
        for (x0, x1, y0, y1) in (
            (g1, g1, y - 0.02 * span, y),
            (g2, g2, y - 0.02 * span, y),
            (g1, g2, y, y),
        )
            push!(shapes, Dict{String,Any}(
                "type" => "line",
                "xref" => xaxis_key, "yref" => yaxis_ref,
                "x0" => x0, "x1" => x1,
                "y0" => y0, "y1" => y1,
                "line" => Dict("color" => "#333333", "width" => 1),
            ))
        end
        x1 = label_positions[g1]
        x2 = label_positions[g2]
        center = n_groups == 1 ? 0.5 : ((x1 + x2) / 2 - 1) / (n_groups - 1)
        push!(annotations, Dict{String,Any}(
            "xref" => "$xaxis_key domain", "yref" => yaxis_ref,
            "x" => center, "xanchor" => "center",
            "y" => y + 0.06 * span,
            "text" => "<b>$(_significance_stars(p))</b>",
            "showarrow" => false,
        ))
        y += step
    end

    lower = min_val >= 0 ? 0.0 : min_val - 0.05 * span
    axis = Dict{String,Any}(pairs(get(layout, yaxis_layout_key, Dict{String,Any}())))
    axis["range"] = [lower, y + 0.1 * span]
    layout[yaxis_layout_key] = axis
end

function alpha_boxplot(groups::Vector{Tuple{String, Vector{String}, Vector{Int}, Vector{Float64}, Vector{Float64}}};
                       show_points::Bool=true,
                       annotate_significance::Bool=false,
                       pairwise_brackets::Bool=false,
                       paired_samples::Bool=false,
                       significance_test::String="kruskal_wallis")
    colours = _palette_hex(length(groups))
    panels = [
        ("y", "x", "yaxis", "y",  "Richness (observed ASVs)", 1),
        ("y2", "x2", "yaxis2", "y2", "Shannon index",          2),
        ("y3", "x3", "yaxis3", "y3", "Gini-Simpson (1 - D)",    3),
    ]
    traces = Any[]
    panel_annotations = Dict{Int, Vector{Dict{String,Any}}}()
    panel_pairwise = Dict{Int, DataFrame}()
    for (pi, (yax, xax, _, _, _, panel_idx)) in enumerate(panels)
        panel_labels = String[]
        panel_values = Float64[]
        panel_sample_ids = String[]
        values_by_label = Dict{String, Vector{Float64}}()
        for (gi, (label, sample_ids, richness_values, shannon_values, simpson_values)) in enumerate(groups)
            vals = pi == 1 ? Float64.(richness_values) : pi == 2 ? shannon_values : simpson_values
            append!(panel_labels, fill(label, length(vals)))
            append!(panel_values, vals)
            append!(panel_sample_ids, sample_ids)
            values_by_label[label] = vals
            line_colour = colours[gi]
            fill_colour = _hex_to_rgba(colours[gi], show_points ? 0.28 : 0.75)
            customdata = Any[
                [sample_ids[i], richness_values[i], shannon_values[i], simpson_values[i]]
                for i in eachindex(sample_ids)
            ]
            push!(traces, Dict{String,Any}(
                "type" => "box", "name" => label,
                "x" => fill(label, length(vals)), "y" => vals, "yaxis" => yax,
                "xaxis" => xax,
                "customdata" => customdata,
                "hovertemplate" => "Group: %{x}<br>Sample: %{customdata[0]}<br>Richness: %{customdata[1]}<br>Shannon: %{customdata[2]:.4f}<br>Simpson: %{customdata[3]:.4f}<extra></extra>",
                "line" => Dict("color" => line_colour, "width" => 2),
                "fillcolor" => fill_colour,
                "boxpoints" => show_points ? "all" : false,
                "jitter" => show_points ? 0.35 : 0.0,
                "pointpos" => show_points ? 0.0 : 0.0,
                "marker" => Dict(
                    "color" => show_points ? _hex_to_rgba(line_colour, 0.65) : line_colour,
                    "size" => show_points ? 7 : 8,
                    "opacity" => 1.0,
                    "line" => Dict("color" => "#ffffff", "width" => show_points ? 0.75 : 0.0),
                ),
                "showlegend" => pi == 1,
                "legendgroup" => label,
            ))
        end
        if length(unique(panel_labels)) >= 2 && significance_test == "kruskal_wallis"
            need_pairwise = pairwise_brackets
            p_value, pairwise_df = _alpha_significance(panel_values, panel_labels, panel_sample_ids;
                                                       pairwise=need_pairwise,
                                                       paired_samples=paired_samples)
            if annotate_significance
            anns = get!(panel_annotations, panel_idx, Dict{String,Any}[])
            push!(anns, Dict{String,Any}(
                "xref" => "paper", "yref" => "paper",
                "x" => 0.98,
                "y" => panel_idx == 1 ? 0.98 : panel_idx == 2 ? 0.64 : 0.30,
                "xanchor" => "right", "yanchor" => "top",
                "text" => "$(paired_samples ? (length(unique(panel_labels)) == 2 ? "Paired Wilcoxon" : "Friedman") : "KW") $(_significance_stars(p_value))<br>$(_format_p_value(p_value))",
                "showarrow" => false,
                "align" => "right",
            ))
            end
            pairwise_brackets && (panel_pairwise[panel_idx] = pairwise_df)
        end
    end
    layout = Dict{String,Any}(
        "title" => Dict("text" => "Alpha diversity comparison"),
        "grid" => Dict("rows" => 3, "columns" => 1, "pattern" => "independent"),
        "boxgap" => 0.3,
        "xaxis"  => Dict("type" => "category"),
        "xaxis2" => Dict("type" => "category"),
        "xaxis3" => Dict("type" => "category"),
        "yaxis"  => Dict("title" => "Richness (observed ASVs)"),
        "yaxis2" => Dict("title" => "Shannon index"),
        "yaxis3" => Dict("title" => "Gini-Simpson (1 - D)"),
        "annotations" => reduce(vcat, values(panel_annotations); init=Any[]),
    )
    if pairwise_brackets
        for (pi, (_, _, yaxis_layout_key, yaxis_ref, _, panel_idx)) in enumerate(panels)
            haskey(panel_pairwise, panel_idx) || continue
            values_by_label = Dict{String, Vector{Float64}}(
                label => (pi == 1 ? Float64.(richness_values) : pi == 2 ? shannon_values : simpson_values)
                for (label, _, richness_values, shannon_values, simpson_values) in groups
            )
            _add_pairwise_annotations!(layout,
                                       panel_idx == 1 ? "x" : "x$panel_idx",
                                       yaxis_ref,
                                       yaxis_layout_key,
                                       [label for (label, _, _, _, _) in groups],
                                       values_by_label,
                                       panel_pairwise[panel_idx])
        end
    end
    Dict("data" => traces, "layout" => layout)
end

function alpha_boxplot(groups::Vector{Tuple{String, Vector{Int}, Vector{Float64}, Vector{Float64}}}; kwargs...)
    expanded = [
        (label,
         ["sample_$i" for i in eachindex(richness_values)],
         richness_values,
         shannon_values,
         simpson_values)
        for (label, richness_values, shannon_values, simpson_values) in groups
    ]
    alpha_boxplot(expanded; kwargs...)
end

## NMDS
"""
    nmds_chart(coords, labels; colour_by, stress) -> Dict

NMDS ordination scatter plot. `coords` is an Nx2 matrix.
"""
const _MARKER_SYMBOLS = [
    "circle", "square", "diamond", "triangle-up", "triangle-down",
    "pentagon", "hexagon", "star", "cross", "x",
]

function nmds_chart(coords::Matrix{Float64}, labels::Vector{String};
                    colour_by::Union{Vector{String},Nothing}=nothing,
                    shape_by::Union{Vector{String},Nothing}=nothing,
                    stress::Union{Float64,Nothing}=nothing)
    n = size(coords, 1)
    cgroups = isnothing(colour_by) ? ["all"] : unique(colour_by)
    sgroups = isnothing(shape_by) ? ["all"] : unique(shape_by)
    colours = _palette_hex(length(cgroups))
    cb = isnothing(colour_by) ? fill("all", n) : colour_by
    sb = isnothing(shape_by) ? fill("all", n) : shape_by

    traces = Any[]
    for (ci, cg) in enumerate(cgroups)
        for (si, sg) in enumerate(sgroups)
            mask = (cb .== cg) .& (sb .== sg)
            any(mask) || continue
            same_label = cg == sg
            name = length(sgroups) <= 1 ? cg : same_label ? cg : "$cg / $sg"
            sym = _MARKER_SYMBOLS[mod1(si, length(_MARKER_SYMBOLS))]
            push!(traces, Dict{String,Any}(
                "type" => "scatter", "mode" => "markers", "name" => name,
                "x" => coords[mask, 1], "y" => coords[mask, 2],
                "text" => labels[mask],
                "legendgroup" => name,
                "marker" => Dict("color" => colours[ci], "size" => 10,
                                 "symbol" => sym),
            ))
        end
    end

    annotations = Any[]
    if !isnothing(stress)
        push!(annotations, Dict{String,Any}(
            "text" => "stress = $(round(stress; digits=3))",
            "xref" => "paper", "yref" => "paper",
            "x" => 0.02, "y" => 0.98,
            "xanchor" => "left", "yanchor" => "top",
            "showarrow" => false,
        ))
    end

    layout = Dict{String,Any}(
        "title" => Dict("text" => "NMDS ordination"),
        "xaxis" => Dict("title" => "NMDS1"),
        "yaxis" => Dict("title" => "NMDS2"),
        "annotations" => annotations,
    )
    Dict("data" => traces, "layout" => layout)
end

## NMDS and PERMANOVA
const _r_lock = ReentrantLock()
const _r_loaded = Ref(false)

function _ensure_r()
    _r_loaded[] && return true
    lock(_r_lock) do
        _r_loaded[] && return true
        try
            RCall.reval("suppressPackageStartupMessages(library(vegan))")
            _r_loaded[] = true
            return true
        catch e
            @warn "R/vegan not available - NMDS and PERMANOVA disabled" exception=e
            return false
        end
    end
end

r_available() = _ensure_r()

"""
    run_nmds(mat; seed=123) -> (coords::Matrix{Float64}, stress::Float64)

NMDS via vegan::metaMDS with Bray-Curtis distance.
`mat` is samples-by-features. Returns NaN-filled results on failure.
"""
function run_nmds(mat::Matrix{Float64}; seed::Integer=123)
    _ensure_r() || return (fill(NaN, size(mat, 1), 2), NaN)
    lock(_r_lock) do
        RCall.globalEnv[:mat] = mat
        RCall.globalEnv[:seed] = Int(seed)
        RCall.reval("""
            set.seed(seed)
            nmds_res <- tryCatch(
                metaMDS(mat, distance = "bray", k = 2, trymax = 200,
                        autotransform = FALSE, trace = 0),
                error = function(e) NULL
            )
            if (!is.null(nmds_res)) {
                nmds_coords <- nmds_res\$points
                nmds_stress <- nmds_res\$stress
            } else {
                nmds_coords <- matrix(NA_real_, nrow = nrow(mat), ncol = 2)
                nmds_stress <- NA_real_
            }
        """)
        coords = RCall.rcopy(RCall.reval("nmds_coords"))::Matrix{Float64}
        stress = RCall.rcopy(RCall.reval("nmds_stress"))::Float64
        RCall.reval("rm(mat, seed, nmds_res, nmds_coords, nmds_stress); gc()")
        coords, stress
    end
end

"""
    run_permanova(mat, metadata; seed=123) -> Union{NamedTuple, Nothing}

PERMANOVA via vegan::adonis2.
`metadata` is a DataFrame with one row per sample and covariate columns.
"""
function run_permanova(mat::Matrix{Float64}, metadata::DataFrame; seed::Integer=123)
    _ensure_r() || return nothing
    covariates = [c for c in names(metadata) if lowercase(c) != "sample" &&
                      length(unique(metadata[!, c])) >= 2]
    isempty(covariates) && return nothing
    formula_rhs = join(covariates, " + ")

    lock(_r_lock) do
        meta_r = copy(metadata)
        RCall.globalEnv[:mat] = mat
        RCall.globalEnv[:meta_r] = meta_r
        RCall.globalEnv[:formula_rhs] = formula_rhs
        RCall.globalEnv[:seed] = Int(seed)
        RCall.reval("""
            set.seed(seed)
            dist_mat <- vegdist(mat, method = "bray")
            form <- as.formula(paste("dist_mat ~", formula_rhs))
            perm_err <- NULL
            perm_res <- tryCatch(
                adonis2(form, data = meta_r, permutations = 999),
                error = function(e) { perm_err <<- conditionMessage(e); NULL }
            )
            if (!is.null(perm_res)) {
                perm_text <- paste(capture.output(print(perm_res)), collapse = "\\n")
                perm_r2 <- perm_res\$R2[1]
                perm_f <- perm_res\$F[1]
                perm_p <- perm_res[["Pr(>F)"]][1]
            } else {
                perm_text <- if (!is.null(perm_err)) perm_err else NA_character_
                perm_r2 <- NA_real_
                perm_f <- NA_real_
                perm_p <- NA_real_
            }
        """)
        txt = RCall.rcopy(RCall.reval("perm_text"))
        r2 = RCall.rcopy(RCall.reval("perm_r2"))
        f_stat = RCall.rcopy(RCall.reval("perm_f"))
        p_val = RCall.rcopy(RCall.reval("perm_p"))
        RCall.reval("rm(mat, meta_r, formula_rhs, seed, dist_mat, form, perm_res, perm_err, perm_text, perm_r2, perm_f, perm_p); gc()")

        ismissing(txt) && return nothing
        # When R's adonis2 threw, txt is the error message and r2/f/p are missing.
        # Return a named tuple with :message so the route can distinguish and surface it.
        ismissing(r2) && return (; message=string(txt))
        (; text=txt,
           r2=r2,
           f_statistic=ismissing(f_stat) ? nothing : f_stat,
           p_value=ismissing(p_val) ? nothing : p_val)
    end
end

end
