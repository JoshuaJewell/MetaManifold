# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: on-demand analysis (alpha diversity, taxa bars, pipeline stats, NMDS, PERMANOVA)

using CSV, DataFrames

using MetaManifold.Analysis: alpha_chart, pipeline_stats_chart,
                             sample_columns, taxonomy_levels, taxon_column, filtered_counts,
                             aggregate_by_taxon, combined_counts_across_runs,
                             alpha_boxplot, nmds_chart, run_nmds, run_permanova, r_available,
                             sequence_column_name, normalise_counts, venn_taxa_present,
                             pool_columns, auto_min_depth, bar_chart
using MetaManifold.Categories, MetaManifold.CompositionLibrary

function _validate_run_request(study::String, run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                 "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    nothing
end

function _require_run_results(study::String, run::String; group::Union{String,Nothing}=nothing)
    err = _validate_run_request(study, run)
    !isnothing(err) && return nothing, err

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return nothing, json_error(404, "no_results",
                                                 "No results for run '$run' - run the pipeline first")
    dir, nothing
end

## Per-run alpha diversity
@post "/api/v1/studies/{study}/runs/{run}/analysis/alpha" function(req,
                                                                    study::String,
                                                                    run::String)
    group = _req_group(req)
    dir, err = _require_run_results(study, run; group)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    table = get(body, :table, "merged")
    params = _body_filter_params(body)
    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    (norm_method, norm_depth) = _analysis_normalisation(study; run, group, config_cache=cfg_cache)

    prefix = let p = get(body, :prefix, nothing); isnothing(p) ? nothing : string(p) end

    _with_analysis_results_table(study, run, table; group) do con, columns
        scols = _filter_by_prefix(sample_columns(con, table), prefix)
        isempty(scols) && return json_error(400, "no_samples", "No sample columns found in table '$table'")
        exclude_conditions = _exclusion_conditions(study, run, group, columns; surface="diversity", config_cache=cfg_cache)
        where_clause, where_params = _analysis_where_clause(params, columns; exclude_conditions)
        mat = filtered_counts(con, table, scols, where_clause, where_params)
        (; mat, kept) = normalise_counts(mat; method=norm_method, depth=norm_depth,
                                         seed=_study_seed(study))
        scols = scols[kept]
        isempty(scols) && return json_error(400, "no_samples",
                                            "All samples dropped below normalisation depth")

        r = Int[]; sh = Float64[]; si = Float64[]
        for i in eachindex(scols)
            counts = round.(Int, mat[i, :])
            push!(r, richness(counts))
            push!(sh, shannon(counts))
            push!(si, simpson(counts))
        end

        fig = alpha_chart(scols, r, sh, si)
        HTTP.Response(200, ["Content-Type" => "application/json"],
                      body=JSON3.write(fig))
    end
end

## Unified chart helpers

# Resolve the composition library without depending on composition.jl (loaded
# after this file).
#
# A single chart request reads the library from three points (row exclusions,
# the Category__ backfill, and the legend colours), and the cross-run chart does
# so once per run, so parsing the YAML afresh at each was 2N+1 parses of one
# small file per figure. The parse is memoised on the file's exact bytes: the
# read still happens on every call, but the read is not the cost, and the key
# cannot go stale. An (mtime, size) key would be cheaper still and is what one
# reaches for first, but it is unsound here: `mtime` is quantised coarsely
# enough that two writes in quick succession share a timestamp, and a same-size
# edit would then be served from the cache. A figure rendered against a
# superseded category set is wrong in a way nothing downstream would catch, so
# the key is the content itself.
#
# Readers must treat the returned Dict as immutable, since they now share one;
# every mutating path goes through composition.jl's `_library`, which parses
# its own copy.
const _CHART_LIB_LOCK  = ReentrantLock()
const _CHART_LIB_CACHE = Ref{Tuple{String,Vector{UInt8},Dict}}(("", UInt8[], Dict{String,Any}()))

function _chart_library()
    path  = joinpath(dirname(ServerState.projects_dir()), "config", "composition.yml")
    bytes = isfile(path) ? read(path) : UInt8[]
    lock(_CHART_LIB_LOCK) do
        cached_path, cached_bytes, cached_lib = _CHART_LIB_CACHE[]
        (cached_path == path && cached_bytes == bytes) && return cached_lib
        lib = CompositionLibrary.load(path)
        _CHART_LIB_CACHE[] = (path, bytes, lib)
        lib
    end
end

## Colour map for a category set: category name -> hex colour.
# Falls back to _UNASSIGNED_COLOUR for "Unassigned" and "#95a5a6" for anything else.
function _category_colour_for(set_name::String)
    cfg = get(_chart_library()["sets"], set_name, nothing)
    colour_map = Dict{String,String}()
    if !isnothing(cfg)
        for cat in get(cfg, "categories", [])
            name = get(cat, "name", nothing)
            col  = get(cat, "colour", nothing)
            (!isnothing(name) && !isnothing(col)) && (colour_map[string(name)] = string(col))
        end
        unassigned_col = get(cfg, "unassigned_colour", "#95a5a6")
        colour_map["Unassigned"] = string(unassigned_col)
    end
    lbl -> get(colour_map, lbl, "#95a5a6")
end

## Core chart-data helper (pure: no HTTP, testable directly).
#
# Resolves label column, applies scope/pooling, drops zero-read rows, and returns
# (segment_labels, sample_names, counts_matrix) or an error dict.
#
# Parameters:
#   con              - DuckDB connection (already open on the annotation table)
#   table            - table name
#   columns          - all column names present in the table
#   all_scols        - all sample columns discovered for this run/table
#   where_clause     - SQL WHERE fragment (may be "")
#   where_params     - positional parameters for where_clause
#   tag              - "rank" or "category"
#   value            - rank name or category-set name
#   subgroup         - nothing | a prefix string | "__pool__"
#   pool_groups      - sub-group labels to pool into when subgroup == "__pool__"
#   pool_fallback    - label used when pool_groups is empty (e.g. the run name)
#   top_n            - top-N limit; ignored for categories (uses typemax(Int))
#   source           - annotation source ("VSEARCH"|"DADA2"), for ensure_columns!
function _chart_data(con, table::String, columns::Vector{String},
                     all_scols::Vector{String},
                     where_clause::String, where_params::Vector,
                     tag::String, value::String,
                     subgroup::Union{String,Nothing},
                     pool_groups::Vector{String},
                     pool_fallback::String,
                     top_n::Int,
                     source::String)
    # Scope sample columns by subgroup.
    scols = if isnothing(subgroup) || subgroup == "__pool__"
        all_scols
    else
        _filter_by_prefix(all_scols, subgroup)
    end
    isempty(scols) && return json_error(400, "no_samples",
                                        "No sample columns for the requested scope")

    # Resolve label column.
    label_col = if tag == "rank"
        if isempty(value)
            levels = taxonomy_levels(con, table)
            isempty(levels) && return json_error(400, "no_taxonomy",
                                                 "No taxonomy columns found")
            col = taxon_column(columns, last(levels))
            isnothing(col) && return json_error(400, "bad_rank",
                                                "Unknown rank '$(last(levels))'")
            col
        else
            col = taxon_column(columns, value)
            isnothing(col) && return json_error(400, "bad_rank",
                                                "Unknown rank '$value'")
            col
        end
    else
        # Ensure the Category__ column exists (lazy backfill for old runs).
        Categories.ensure_columns!(con, table, source, [value];
                                   library=_chart_library())
        col = Categories.column_name(value)
        # Verify the column now exists; it may still be absent when the set
        # config file does not exist (ensure_columns! skips missing sets).
        present = Set(string.(DataFrame(DBInterface.execute(con,
            "SELECT column_name FROM information_schema.columns WHERE table_name = ?",
            [table])).column_name))
        col in present || return json_error(404, "category_set_not_found",
                                            "Category set '$value' not found")
        col
    end

    # For categories, never collapse into "Other".
    effective_top_n = (tag == "category") ? typemax(Int) : top_n

    agg = aggregate_by_taxon(con, table, scols, label_col, where_clause, where_params)
    nrow(agg) == 0 && return json_error(400, "no_data", "No data after filtering")

    segment_labels = String.(agg.taxon)
    counts = Matrix{Float64}(agg[:, scols])  # segments x samples

    # Zero-read guard: drop label rows whose sum across retained samples is zero.
    row_totals = vec(sum(counts, dims=2))
    keep_rows  = row_totals .> 0
    if !all(keep_rows)
        segment_labels = segment_labels[keep_rows]
        counts         = counts[keep_rows, :]
    end
    isempty(segment_labels) && return json_error(400, "no_data",
                                                  "All labels have zero reads")

    # Pool sample columns when requested.
    if subgroup == "__pool__"
        scols, counts = pool_columns(scols, counts, pool_groups;
                                     fallback_label=pool_fallback)
    end

    (; segment_labels, sample_names=scols, counts, effective_top_n)
end

## Per-run unified chart
@post "/api/v1/studies/{study}/runs/{run}/analysis/chart" function(req,
                                                                    study::String,
                                                                    run::String)
    group = _req_group(req)
    dir, err = _require_run_results(study, run; group)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    table    = string(get(body, :table, "merged"))
    tag      = string(get(body, :tag, "rank"))
    value    = string(get(body, :value, ""))
    top_n    = Int(get(body, :top_n, 15))
    relative = Bool(get(body, :relative, true))
    mode     = string(get(body, :mode, "stacked"))
    subgroup = let v = get(body, :subgroup, nothing)
        (isnothing(v) || v === nothing) ? nothing : string(v)
    end
    params = _body_filter_params(body)
    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    (norm_method, norm_depth) = _analysis_normalisation(study; run, group,
                                                         config_cache=cfg_cache)

    # Resolve sub-group prefixes for pooling (used when subgroup == "__pool__").
    run_data_dir = joinpath(ServerState.data_dir(), study,
                            isnothing(group) ? run : joinpath(group, run))
    pool_groups = _is_pooled(run_data_dir) ? _subgroup_names(run_data_dir) : String[]

    # Only the category branch backfills Category__ columns; rank charts read-only.
    _with_analysis_results_table(study, run, table; group,
                                 readonly = tag != "category") do con, columns
        all_scols = sample_columns(con, table)
        isempty(all_scols) && return json_error(400, "no_samples",
                                                "No sample columns found in table '$table'")
        # Category-tagged rendering is the composition surface; rank is taxa.
        surface = tag == "category" ? "composition" : "taxa"
        exclude_conditions = _exclusion_conditions(study, run, group, columns; surface, config_cache=cfg_cache)
        where_clause, where_params = _analysis_where_clause(params, columns;
                                                             exclude_conditions)

        # Source resolves the taxonomy side for category backfill; rank charts ignore it.
        tag_source = tag == "category" ? _tagging_source(study, run; group) : ""
        result = _chart_data(con, table, columns, all_scols,
                             where_clause, where_params,
                             tag, value, subgroup,
                             pool_groups, run, top_n, tag_source)
        result isa HTTP.Response && return result

        # normalise_counts expects samples x features; counts is segments x samples,
        # so transpose, normalise, transpose back.
        counts_t = permutedims(result.counts)
        norm = normalise_counts(counts_t; method=norm_method, depth=norm_depth,
                                seed=_study_seed(study))
        isempty(norm.kept) && return json_error(400, "no_samples",
                                                "All samples dropped below normalisation depth")
        counts  = permutedims(norm.mat)
        scols   = result.sample_names[norm.kept]

        colour_for = (tag == "category") ? _category_colour_for(value) : nothing
        fig = bar_chart(result.segment_labels, scols, counts;
                        top_n=result.effective_top_n, relative, mode, colour_for)
        HTTP.Response(200, ["Content-Type" => "application/json"],
                      body=JSON3.write(fig))
    end
end

## Pipeline stats
@get "/api/v1/studies/{study}/runs/{run}/analysis/pipeline-stats" function(req,
                                                                            study::String,
                                                                            run::String)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err
    group = _req_group(req)
    run_dir = _run_project_dir(study, run; group)
    stats_csv = joinpath(run_dir, "dada2", "Tables", "pipeline_stats.csv")
    isfile(stats_csv) || return json_error(404, "no_stats",
                                                "No pipeline stats - run DADA2 first")

    stats_df = CSV.read(stats_csv, DataFrame)
    first_col = names(stats_df)[1]
    first_col != "sample" && rename!(stats_df, first_col => "sample")

    fig = pipeline_stats_chart(stats_df)
    isnothing(fig) && return json_error(400, "no_data", "Empty stats table")
    HTTP.Response(200, ["Content-Type" => "application/json"],
                  body=JSON3.write(fig))
end

## Taxonomy ranks discovery
@get "/api/v1/studies/{study}/runs/{run}/analysis/ranks" function(req,
                                                                    study::String,
                                                                    run::String)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err
    group = _req_group(req)
    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json([])

    table = get(HTTP.queryparams(req), "table", "merged")
    _with_analysis_results_table(study, run, table; group) do con, _columns
        json(taxonomy_levels(con, table))
    end
end

## Cross-run helpers
_opt_string(spec, key) = let v = get(spec, key, nothing)
    isnothing(v) || isempty(string(v)) ? nothing : string(v)
end

function _resolve_run_duckdb(study::String, run_spec)
    run_name = string(get(run_spec, :run, ""))
    group  = _opt_string(run_spec, :group)
    prefix = _opt_string(run_spec, :prefix)
    source = _opt_string(run_spec, :source)
    dir = _require_duckdb(study, run_name; group)
    isnothing(dir) && return nothing
    label = if !isnothing(prefix)
        prefix
    elseif !isnothing(group)
        "$group/$run_name"
    else
        run_name
    end
    (; run=run_name, group, dir, label, prefix, source)
end

"""Filter sample columns to those matching a prefix (e.g. "SubgroupName_")."""
function _filter_by_prefix(scols::Vector{String}, prefix::Union{String,Nothing})
    isnothing(prefix) && return scols
    pfx = prefix * "_"
    filter(c -> startswith(c, pfx), scols)
end

# Keep columns matching any of several sub-group prefixes, preserving input order.
# An empty prefix list means no restriction, mirroring the `nothing` case above.
function _filter_by_prefix(scols::Vector{String}, prefixes::Vector{String})
    isempty(prefixes) && return scols
    pfxs = [p * "_" for p in prefixes]
    filter(c -> any(p -> startswith(c, p), pfxs), scols)
end

function _resolved_group_label(resolved)
    if !isnothing(resolved.prefix)
        resolved.prefix
    elseif !isnothing(resolved.group)
        resolved.group
    else
        resolved.run
    end
end

function _resolved_run_label(resolved)
    if !isnothing(resolved.group)
        "$(resolved.group)/$(resolved.run)"
    else
        resolved.run
    end
end

function _study_seed(study::String)
    resolved = _resolve_config(study)
    Int(get(get(resolved, "seed", (; value=DEFAULT_SEED, source="default")), :value, DEFAULT_SEED))
end

# Resolve a run's config cascade, memoised in `config_cache` by (study, run, group).
function _resolved_run_config(study::String, run, group, config_cache)
    key = (study, something(run, ""), something(group, ""))
    if !isnothing(config_cache) && haskey(config_cache, key)
        return config_cache[key]
    end
    cfg = _resolve_config(study, run, group)
    !isnothing(config_cache) && (config_cache[key] = cfg)
    cfg
end

## Category-based figure exclusion
# The chart surfaces an exclusion may apply to. "diversity" covers alpha, NMDS
# and PERMANOVA; "taxa" is the rank-tagged chart; "composition" is the
# category-tagged chart; "venn" the presence/absence sets.
const _EXCLUSION_SURFACES = Set(["diversity", "taxa", "composition", "venn"])

# Resolve the configured `analysis.exclude_categories` for a run into a vector of
# (set, category, surfaces) specs. Each names a composition category set and the
# single category within it whose taxa should be dropped. `surfaces` is the set
# of chart surfaces the spec applies to, parsed from an optional `apply_to` list;
# when `apply_to` is absent the spec applies to every surface (`surfaces` is
# `nothing`). Unknown surface names are dropped with a warning.
function _analysis_exclude_categories(study::String;
                                      run::Union{String,Nothing}=nothing,
                                      group::Union{String,Nothing}=nothing,
                                      config_cache::Union{Dict,Nothing}=nothing)
    resolved = _resolved_run_config(study, run, group, config_cache)
    entry = get(resolved, "analysis.exclude_categories", (; value=[], source="default"))
    raw = get(entry, :value, [])
    specs = @NamedTuple{set::String, category::String, surfaces::Union{Nothing,Set{String}}}[]
    raw isa AbstractVector || return specs
    for item in raw
        item isa AbstractDict || continue
        set = string(get(item, "set", ""))
        category = string(get(item, "category", ""))
        (isempty(set) || isempty(category)) && continue
        surfaces = _parse_apply_to(get(item, "apply_to", nothing); set, category)
        push!(specs, (; set, category, surfaces))
    end
    specs
end

# Parse an `apply_to` value into a set of known surfaces, or `nothing` (all).
# A missing or malformed value means "all surfaces"; an explicit list is filtered
# to the known surfaces, and unknown entries are warned about and dropped.
function _parse_apply_to(raw; set::String, category::String)
    raw isa AbstractVector || return nothing
    surfaces = Set{String}()
    for s in raw
        name = lowercase(strip(string(s)))
        if name in _EXCLUSION_SURFACES
            push!(surfaces, name)
        else
            @warn "exclude_categories: unknown apply_to surface; ignoring" set category surface=name
        end
    end
    surfaces
end

# Build SQL WHERE fragments that drop rows classified into an excluded category,
# for the given chart `surface` (see `_EXCLUSION_SURFACES`). A spec applies only
# when its `surfaces` is `nothing` (all) or contains `surface`, so an exclusion
# can be kept out of, say, the composition chart while still cleaning diversity.
# The composition category CASE expression is evaluated inline and compared to
# the excluded category name, so no Category__ column need be materialised and
# the query stays read-only. Column references are bare (no table alias), which
# matches the context in which these fragments are appended. `strict=true` gates
# on exact realisability so a degraded filter drops nothing rather than the wrong
# rows; a warning is logged for each skipped spec.
function _exclusion_conditions(study::String, run, group, columns::Vector{String};
                               surface::String, config_cache::Union{Dict,Nothing}=nothing)
    isnothing(run) && return String[]
    specs = filter(s -> isnothing(s.surfaces) || surface in s.surfaces,
                   _analysis_exclude_categories(study; run, group, config_cache))
    isempty(specs) && return String[]
    source = _tagging_source(study, run; group)
    lib = _chart_library()
    filters = lib["filters"]
    col_set = Set(columns)
    conds = String[]
    for spec in specs
        cfg = get(lib["sets"], spec.set, nothing)
        isnothing(cfg) && continue
        cats = get(cfg, "categories", [])
        case = Categories.category_case_when(cats, col_set, source;
                                             filters, table_alias="", strict=true)
        # Drop rows only when the set is exactly realisable AND the excluded
        # category is reachable in the CASE, either as its own branch (THEN) or
        # as the catch-all (ELSE); otherwise the condition would silently exclude
        # nothing or the wrong rows.
        cat_lit = Categories._sql_str(spec.category)
        if isnothing(case) || !(occursin("THEN $cat_lit", case) || occursin("ELSE $cat_lit", case))
            @warn "exclude_categories: category not classifiable for this table; skipping exclusion" set=spec.set category=spec.category
            continue
        end
        push!(conds, "($case) != $cat_lit")
    end
    conds
end

function _analysis_normalisation(study::String;
                                  run::Union{String,Nothing}=nothing,
                                  group::Union{String,Nothing}=nothing,
                                  config_cache::Union{Dict,Nothing}=nothing)
    resolved = _resolved_run_config(study, run, group, config_cache)
    method_entry = get(resolved, "analysis.normalisation",       (; value="none", source="default"))
    depth_entry  = get(resolved, "analysis.normalisation_depth", (; value=0,      source="default"))
    method = String(get(method_entry, :value, "none"))
    depth  = Int(get(depth_entry,  :value, 0))
    (method, depth)
end

function _analysis_where_clause(params, columns::Vector{String};
                                exclude_conditions::Vector{String}=String[])
    where_clause, where_params = _build_where(params, columns)
    for cond in exclude_conditions
        where_clause = isempty(where_clause) ? "WHERE $cond" : "$where_clause AND $cond"
    end
    where_clause, where_params
end

# Open a run's merged results DB for analysis and invoke `f(con, columns)`.
# The merged table carries taxonomy ranks, Category__<set> columns and per-sample
# counts, so every analysis reads it directly; the per-source annotation DBs of
# the quarantined FuncDB workflow are not consulted. Pass `readonly=false` when
# the body backfills Category__ columns via `Categories.ensure_columns!`.
function _with_analysis_results_table(f::Function, study::String, run::String, table::String;
                                      group::Union{String,Nothing}=nothing,
                                      readonly::Bool=true)
    merge_dir = _require_duckdb(study, run; group)
    isnothing(merge_dir) && return json_error(404, "no_results",
        "No results for run '$run' - run the pipeline first")
    opener = readonly ? with_results_db : with_results_db_write
    opener(merge_dir) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return json_error(404, "table_not_found",
                                              "Table '$table' not found in results database")
        f(con, columns)
    end
end

# Cross-run analogue: open the merged results DB of a run already resolved by
# `_resolve_run_duckdb` (which carries its `dir`), invoking `f(con, columns)`.
# Returns `nothing` when the table is absent so accumulating loops simply skip it.
function _with_resolved_results_table(f::Function, resolved, table::String;
                                      readonly::Bool=true)
    opener = readonly ? with_results_db : with_results_db_write
    opener(resolved.dir) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return nothing
        f(con, columns)
    end
end

function _study_alpha_plot_config(study::String)
    resolved = _resolve_config(study)
    get_value(key, default) = get(get(resolved, key, (; value=default, source="default")), :value, default)
    (;
        show_points = Bool(get_value("analysis.alpha.show_points", true)),
        annotate_significance = Bool(get_value("analysis.alpha.annotate_significance", false)),
        pairwise_brackets = Bool(get_value("analysis.alpha.pairwise_brackets", false)),
        paired_samples = Bool(get_value("analysis.alpha.paired_samples", false)),
        significance_test = String(get_value("analysis.alpha.significance_test", "kruskal_wallis")),
    )
end

function _comparison_sample_id(sample_col::String, resolved)
    sample_id = sample_col
    if !isnothing(resolved.prefix)
        prefix = resolved.prefix * "_"
        startswith(sample_id, prefix) && (sample_id = sample_id[length(prefix)+1:end])
    end
    # Normalise common naming schemes so paired alpha tests can match the same
    # biological sample across tissues/runs, e.g. 12c_v vs 12l_v -> 12.
    sample_id = replace(sample_id, r"_[^_]+$" => "")
    sample_id = replace(sample_id, r"([0-9])[A-Za-z]$" => s"\1")
    sample_id
end

function _comparison_pair_key(sample_col::String, resolved; mode::Symbol)
    if mode == :run
        # Study/group-level run comparison: preserve subgroup+tissue identity,
        # drop only the run/method suffix so Caecum_12c_m pairs with Caecum_12c_v.
        return replace(sample_col, r"_[^_]+$" => "")
    else
        # Within-run subgroup comparison: pair by the underlying animal/sample id,
        # ignoring subgroup prefix, run/method suffix, and tissue suffix.
        return _comparison_sample_id(sample_col, resolved)
    end
end

function _expand_comparison_run_specs(study::String, runs_spec; aggregate::Bool=false)
    expanded = NamedTuple[]
    for spec in runs_spec
        run_name = string(get(spec, :run, ""))
        isempty(run_name) && continue
        group  = _opt_string(spec, :group)
        prefix = _opt_string(spec, :prefix)
        source = _opt_string(spec, :source)
        if aggregate
            push!(expanded, (; run=run_name, group, prefix=nothing, source))
            continue
        end

        if !isnothing(prefix)
            push!(expanded, (; run=run_name, group, prefix, source))
            continue
        end

        data_rel = isnothing(group) ? run_name : joinpath(group, run_name)
        data_dir = joinpath(ServerState.data_dir(), study, data_rel)
        if _is_pooled(data_dir)
            for subgroup in _subgroup_names(data_dir)
                push!(expanded, (; run=run_name, group, prefix=subgroup, source))
            end
        else
            push!(expanded, (; run=run_name, group, prefix=nothing, source))
        end
    end
    expanded
end

function _collect_cross_run_asvs(study::String, runs_spec, table, params; aggregate::Bool=false)
    run_data = Tuple{String, Vector{String}, DataFrame}[]
    group_labels = String[]
    run_labels = String[]
    missing_seq = false
    cfg_cache = Dict{Tuple{String,String,String}, Any}()

    for spec in _expand_comparison_run_specs(study, runs_spec; aggregate)
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && continue
        _with_resolved_results_table(resolved, table) do con, columns
            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return

            seq_col = sequence_column_name(columns)
            if isnothing(seq_col)
                missing_seq = true
                return
            end

            exclude_conditions = _exclusion_conditions(study, resolved.run, resolved.group, columns; surface="diversity", config_cache=cfg_cache)
            where_clause, where_params = _analysis_where_clause(params, columns; exclude_conditions)
            seq_filter = isempty(where_clause) ?
                "WHERE \"$seq_col\" IS NOT NULL AND TRIM(\"$seq_col\") != ''" :
                "$where_clause AND \"$seq_col\" IS NOT NULL AND TRIM(\"$seq_col\") != ''"

            sum_exprs = join(["SUM(COALESCE(\"$c\", 0)) AS \"$c\"" for c in scols], ", ")
            sql = """
                SELECT "$seq_col" AS "sequence", $sum_exprs
                FROM "$table" $seq_filter
                GROUP BY "$seq_col"
            """
            df = DataFrame(DBInterface.execute(con, sql, where_params))
            nrow(df) == 0 && return

            push!(run_data, (resolved.label, scols, df))
            group_label = _resolved_group_label(resolved)
            run_label = _resolved_run_label(resolved)
            append!(group_labels, fill(group_label, length(scols)))
            append!(run_labels, fill(run_label, length(scols)))
        end
    end

    run_data, group_labels, run_labels, missing_seq
end

function _drop_empty_samples(mat::Matrix{Float64}, aligned::AbstractVector...)
    keep = vec(sum(mat; dims=2) .> 0)
    filtered = Any[mat[keep, :]]
    for values in aligned
        push!(filtered, values[keep])
    end
    Tuple(filtered), count(keep), length(keep)
end

## Resolve the rarefaction depth shared across runs: a configured value wins;
## auto (0) resolves to the pooled minimum positive library size. Skipped for
## method "none", where normalise_counts ignores the depth entirely.
function _resolve_cross_run_depth(method::String, configured_depth::Int, matrices)
    (method == "none" || configured_depth != 0) && return configured_depth
    auto_min_depth(Iterators.flatten(vec(sum(m; dims=2)) for m in matrices))
end

function _apply_normalisation(mat::Matrix{Float64}, method::String, depth::Int,
                              seed::Int, aligned::AbstractVector...)
    norm = normalise_counts(mat; method, depth, seed)
    filtered = Any[norm.mat]
    for values in aligned
        push!(filtered, values[norm.kept])
    end
    Tuple(filtered), length(norm.kept)
end

## Cross-run alpha comparison
@post "/api/v1/studies/{study}/analysis/alpha" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(String(req.body))
    runs_spec = get(body, :runs, [])
    isempty(runs_spec) && return json_error(400, "no_runs", "Provide at least one run")
    table = get(body, :table, "merged")
    params = _body_filter_params(body)

    aggregate = Bool(get(body, :aggregate, false))
    expanded_specs = _expand_comparison_run_specs(study, runs_spec; aggregate)
    resolved_specs = filter(!isnothing, [_resolve_run_duckdb(study, spec) for spec in expanded_specs])
    isempty(resolved_specs) && return json_error(400, "no_data", "No data found for any run")

    compare_mode = length(unique(_resolved_run_label(r) for r in resolved_specs)) > 1 ? :run : :subgroup
    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    (norm_method, norm_depth_cfg) = _analysis_normalisation(study)

    # First pass: collect raw matrices (fetched inside annotation DB closures)
    collected = Tuple{Matrix{Float64}, Vector{String}, Any}[]
    for resolved in resolved_specs
        _with_resolved_results_table(resolved, table) do con, columns
            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return
            exclude_conditions = _exclusion_conditions(study, resolved.run, resolved.group, columns; surface="diversity", config_cache=cfg_cache)
            where_clause, where_params = _analysis_where_clause(params, columns; exclude_conditions)
            mat = filtered_counts(con, table, scols, where_clause, where_params)
            push!(collected, (mat, scols, resolved))
        end
    end

    isempty(collected) && return json_error(400, "no_data", "No data found for any run")

    norm_depth = _resolve_cross_run_depth(norm_method, norm_depth_cfg,
                                          (mat for (mat, _, _) in collected))

    seed = _study_seed(study)

    # Second pass: normalise each run's matrix and compute diversity metrics
    groups = Dict{String, NamedTuple{(:sample_ids, :richness, :shannon, :simpson),
                                     Tuple{Vector{String}, Vector{Int}, Vector{Float64}, Vector{Float64}}}}()
    for (raw_mat, raw_scols, resolved) in collected
        (; mat, kept) = normalise_counts(raw_mat; method=norm_method, depth=norm_depth, seed)
        scols = raw_scols[kept]
        isempty(scols) && continue

        r = Int[]; sh = Float64[]; si = Float64[]
        for i in eachindex(scols)
            counts = round.(Int, mat[i, :])
            push!(r, richness(counts))
            push!(sh, shannon(counts))
            push!(si, simpson(counts))
        end
        sample_ids = [_comparison_pair_key(s, resolved; mode=compare_mode) for s in scols]
        label = compare_mode == :run ? _resolved_run_label(resolved) : _resolved_group_label(resolved)
        bucket = get!(groups, label, (; sample_ids=String[], richness=Int[], shannon=Float64[], simpson=Float64[]))
        append!(bucket.sample_ids, sample_ids)
        append!(bucket.richness, r)
        append!(bucket.shannon, sh)
        append!(bucket.simpson, si)
    end

    isempty(groups) && return json_error(400, "no_data", "No data found for any run")
    ordered = [(label, vals.sample_ids, vals.richness, vals.shannon, vals.simpson)
               for (label, vals) in sort(collect(groups); by = first)]
    alpha_cfg = _study_alpha_plot_config(study)
    fig = alpha_boxplot(ordered;
                        show_points=alpha_cfg.show_points,
                        annotate_significance=alpha_cfg.annotate_significance,
                        pairwise_brackets=alpha_cfg.pairwise_brackets,
                        paired_samples=alpha_cfg.paired_samples,
                        significance_test=alpha_cfg.significance_test)
    HTTP.Response(200, ["Content-Type" => "application/json"],
                  body=JSON3.write(fig))
end

## Server capabilities
@get "/api/v1/capabilities" function(req)
    json((; r_available=r_available()))
end

## Cross-run NMDS
@post "/api/v1/studies/{study}/analysis/nmds" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    !r_available() && return json_error(503, "r_unavailable",
                                             "R/vegan is not available - install R and the vegan package")
    body = JSON3.read(String(req.body))
    runs_spec = get(body, :runs, [])
    length(runs_spec) < 2 && return json_error(400, "too_few_runs",
                                                    "NMDS requires at least 2 runs")
    table = get(body, :table, "merged")
    params = _body_filter_params(body)
    aggregate = Bool(get(body, :aggregate, false))
    (norm_method, norm_depth) = _analysis_normalisation(study)

    run_data, group_labels, run_name_labels, missing_seq = _collect_cross_run_asvs(study, runs_spec, table, params; aggregate)

    missing_seq && return json_error(400, "no_sequence_data",
                                         "Table '$table' does not contain a DNA sequence column required for cross-run NMDS/PERMANOVA (expected `sequence` or `Sequence`, as in `merged` or `asv_counts`)")
    length(run_data) < 2 && return json_error(400, "too_few_runs",
                                                   "Need data from at least 2 runs for NMDS")
    mat, all_samples, _, _ = combined_asv_counts_across_runs(run_data)
    (filtered, kept, total) = _drop_empty_samples(mat, all_samples, group_labels, run_name_labels)
    mat, all_samples, group_labels, run_name_labels = filtered
    kept < total && @info "NMDS: dropped $(total - kept) empty samples before ordination"
    (filtered, nkept) = _apply_normalisation(mat, norm_method, norm_depth,
                                             _study_seed(study),
                                             all_samples, group_labels, run_name_labels)
    mat, all_samples, group_labels, run_name_labels = filtered
    nkept < kept &&
        @info "NMDS: dropped $(kept - nkept) samples below normalisation depth"
    size(mat, 1) < 3 && return json_error(400, "too_few_samples",
                                               "Need at least 3 non-empty samples for NMDS")

    coords, stress = run_nmds(mat; seed=_study_seed(study))
    any(isnan, coords) && return json_error(500, "nmds_failed", "NMDS computation failed")

    # Use a single visual dimension when only one factor varies; otherwise encode
    # run by colour and subgroup/group by shape.
    unique_groups = unique(group_labels)
    unique_runs = unique(run_name_labels)
    colour_by = if length(unique_runs) <= 1
        group_labels
    else
        run_name_labels
    end
    shape_by = if length(unique_runs) <= 1 || length(unique_groups) <= 1
        nothing
    else
        group_labels
    end
    fig = nmds_chart(coords, all_samples;
                     colour_by=colour_by, stress, shape_by=shape_by)
    HTTP.Response(200, ["Content-Type" => "application/json"],
                  body=JSON3.write(fig))
end

## Cross-run PERMANOVA
@post "/api/v1/studies/{study}/analysis/permanova" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    !r_available() && return json_error(503, "r_unavailable",
                                             "R/vegan is not available")
    body = JSON3.read(String(req.body))
    runs_spec = get(body, :runs, [])
    length(runs_spec) < 2 && return json_error(400, "too_few_runs",
                                                    "PERMANOVA requires at least 2 runs")
    table = get(body, :table, "merged")
    params = _body_filter_params(body)
    aggregate = Bool(get(body, :aggregate, false))
    (norm_method, norm_depth) = _analysis_normalisation(study)

    run_data, group_labels, run_labels, missing_seq = _collect_cross_run_asvs(study, runs_spec, table, params; aggregate)

    missing_seq && return json_error(400, "no_sequence_data",
                                         "Table '$table' does not contain a DNA sequence column required for cross-run NMDS/PERMANOVA (expected `sequence` or `Sequence`, as in `merged` or `asv_counts`)")
    length(run_data) < 2 && return json_error(400, "too_few_runs",
                                                   "Need data from at least 2 runs")
    mat, all_samples, _, _ = combined_asv_counts_across_runs(run_data)
    (filtered, kept, total) = _drop_empty_samples(mat, all_samples, group_labels, run_labels)
    mat, all_samples, group_labels, run_labels = filtered
    kept < total && @info "PERMANOVA: dropped $(total - kept) empty samples before analysis"
    (filtered, nkept) = _apply_normalisation(mat, norm_method, norm_depth,
                                             _study_seed(study),
                                             all_samples, group_labels, run_labels)
    mat, all_samples, group_labels, run_labels = filtered
    nkept < kept &&
        @info "PERMANOVA: dropped $(kept - nkept) samples below normalisation depth"
    size(mat, 1) < 3 && return json_error(400, "too_few_samples",
                                               "Need at least 3 non-empty samples for PERMANOVA")

    metadata = DataFrame(sample=all_samples, group=group_labels, run=run_labels)
    result = run_permanova(mat, metadata; seed=_study_seed(study))
    isnothing(result) && return json_error(500, "permanova_failed", "PERMANOVA computation failed")
    hasproperty(result, :message) && return json_error(500, "permanova_failed",
                                                           "PERMANOVA computation failed: $(result.message)")
    json(result)
end

## Cross-run unified chart
@post "/api/v1/studies/{study}/analysis/chart" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(String(req.body))
    runs_spec = get(body, :runs, [])
    isempty(runs_spec) && return json_error(400, "no_runs", "Provide at least one run")
    table    = string(get(body, :table, "merged"))
    tag      = string(get(body, :tag, "rank"))
    value    = string(get(body, :value, ""))
    top_n    = Int(get(body, :top_n, 15))
    relative = Bool(get(body, :relative, true))
    mode     = string(get(body, :mode, "stacked"))
    subgroup = let v = get(body, :subgroup, nothing)
        (isnothing(v) || v === nothing) ? nothing : string(v)
    end
    params   = _body_filter_params(body)
    (norm_method, norm_depth_cfg) = _analysis_normalisation(study)
    cfg_cache = Dict{Tuple{String,String,String}, Any}()

    # Collect per-run aggregated counts.
    collected = Tuple{String, Vector{String}, DataFrame}[]
    effective_top_n = (tag == "category") ? typemax(Int) : top_n

    for spec in runs_spec
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && continue
        # Only the category branch backfills Category__ columns; rank charts read-only.
        _with_resolved_results_table(resolved, table; readonly = tag != "category") do con, columns

            # Scope sample columns to the requested subgroup prefix (not "__pool__" here).
            prefix_scope = (isnothing(subgroup) || subgroup == "__pool__") ?
                            resolved.prefix : subgroup
            scols = _filter_by_prefix(sample_columns(con, table), prefix_scope)
            isempty(scols) && return nothing
            surface = tag == "category" ? "composition" : "taxa"
            exclude_conditions = _exclusion_conditions(study, resolved.run, resolved.group, columns; surface, config_cache=cfg_cache)
            where_clause, where_params = _analysis_where_clause(params, columns;
                                                                exclude_conditions)

            label_col = if tag == "rank"
                r = isempty(value) ? begin
                        levels = taxonomy_levels(con, table)
                        isempty(levels) && return nothing
                        last(levels)
                    end : value
                col = taxon_column(columns, string(r))
                isnothing(col) && return json_error(400, "bad_rank",
                                                    "Unknown rank '$r'")
                col
            else
                # The tagging source backfills Category__ columns for older runs.
                tag_source = _tagging_source(study, resolved.run; group=resolved.group)
                Categories.ensure_columns!(con, table, tag_source, [value];
                                           library=_chart_library())
                col = Categories.column_name(value)
                # Guard: skip this run if the category column is absent (set config missing).
                present = Set(string.(DataFrame(DBInterface.execute(con,
                    "SELECT column_name FROM information_schema.columns WHERE table_name = ?",
                    [table])).column_name))
                col in present || return nothing
                col
            end

            agg = aggregate_by_taxon(con, table, scols, label_col,
                                     where_clause, where_params)
            nrow(agg) == 0 && return nothing

            # Zero-read guard: drop label rows that are all-zero across scols.
            row_totals = vec(sum(Matrix{Float64}(agg[:, scols]), dims=2))
            keep_rows  = row_totals .> 0
            if !all(keep_rows)
                agg = agg[keep_rows, :]
            end
            nrow(agg) == 0 && return nothing

            label = _resolved_group_label(resolved)
            push!(collected, (label, scols, agg))
            nothing
        end
    end

    isempty(collected) && return json_error(400, "no_data", "No data found for any run")

    # Combine across runs via the existing helper.
    mat, all_samples, segment_labels, run_labels = combined_counts_across_runs(collected)

    # Normalise (samples x segments).
    norm_depth = _resolve_cross_run_depth(norm_method, norm_depth_cfg, (mat,))
    seed = _study_seed(study)
    (; mat, kept) = normalise_counts(mat; method=norm_method, depth=norm_depth, seed)
    all_samples = all_samples[kept]
    run_labels  = run_labels[kept]
    isempty(kept) && return json_error(400, "no_samples",
                                            "All samples dropped below normalisation depth")

    # Transpose to segments x samples.
    counts = permutedims(mat)

    # Zero-read guard on the combined matrix.
    row_totals = vec(sum(counts, dims=2))
    keep_rows  = row_totals .> 0
    if !all(keep_rows)
        segment_labels = segment_labels[keep_rows]
        counts         = counts[keep_rows, :]
    end

    # Pool: cross-run always pools by run label when subgroup == "__pool__" or by default.
    unique_labels = unique(run_labels)
    if isnothing(subgroup) || subgroup == "__pool__"
        scols, counts = pool_columns(all_samples, counts, unique_labels)
    else
        scols = all_samples
    end

    colour_for = (tag == "category") ? _category_colour_for(value) : nothing
    fig = bar_chart(segment_labels, scols, counts;
                    top_n=effective_top_n, relative, mode, colour_for)
    HTTP.Response(200, ["Content-Type" => "application/json"],
                  body=JSON3.write(fig))
end

## Cross-run taxon Venn sets
"""
    _venn_condition_labels(conditions) -> Vector{String}

Build a user-facing label for each condition in the Venn diagram, including
only the identity components (group / run / prefix) that actually differ
across the selected conditions. This avoids ambiguity when e.g. multiple
groups share the same pooled-run subgroup prefixes.
"""
function _venn_condition_labels(conditions)
    groups_differ   = length(unique(c.group   for c in conditions)) > 1
    runs_differ     = length(unique(c.run     for c in conditions)) > 1
    prefixes_differ = length(unique(c.prefix  for c in conditions)) > 1
    labels = String[]
    for c in conditions
        parts = String[]
        groups_differ   && !isnothing(c.group)  && push!(parts, c.group)
        runs_differ                              && push!(parts, c.run)
        prefixes_differ && !isnothing(c.prefix) && push!(parts, c.prefix)
        if isempty(parts)
            # Nothing varies (only one condition); fall back to the most specific identifier.
            push!(parts, something(c.prefix, c.run))
        end
        push!(labels, join(parts, "/"))
    end
    labels
end

@post "/api/v1/studies/{study}/analysis/venn" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body   = JSON3.read(String(req.body))
    runs_spec = get(body, :runs, [])
    isempty(runs_spec) && return json_error(400, "no_runs", "Provide at least one run")
    table  = string(get(body, :table, "merged"))
    rank   = string(get(body, :rank,  "Genus"))
    params = _body_filter_params(body)

    # Collect each condition with its identity components so we can compute
    # disambiguated labels after seeing the full set of selected conditions.
    aggregate = Bool(get(body, :aggregate, false))
    conditions = NamedTuple{
        (:group, :run, :prefix, :taxa),
        Tuple{Union{String,Nothing}, String, Union{String,Nothing}, Vector{String}}
    }[]
    cfg_cache  = Dict{Tuple{String,String,String}, Any}()

    for spec in _expand_comparison_run_specs(study, runs_spec; aggregate)
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && continue

        _with_resolved_results_table(resolved, table) do con, columns
            levels = taxonomy_levels(con, table)
            isempty(levels) && return
            effective_rank = rank in levels ? rank : last(levels)
            rank_col = taxon_column(columns, effective_rank)
            isnothing(rank_col) && return

            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return

            exclude_conditions = _exclusion_conditions(study, resolved.run, resolved.group, columns; surface="venn", config_cache=cfg_cache)
            where_clause, where_params = _analysis_where_clause(params, columns;
                                                                exclude_conditions)
            taxa = venn_taxa_present(con, table, scols, rank_col,
                                     where_clause, where_params)
            push!(conditions, (; group=resolved.group, run=resolved.run,
                                  prefix=resolved.prefix, taxa))
        end
    end

    length(conditions) < 2 && return json_error(400, "too_few_conditions",
        "Need data from at least 2 conditions for the taxon overlap diagram")

    labels = _venn_condition_labels(conditions)
    sets = [(; name=labels[i], taxa=conditions[i].taxa) for i in eachindex(conditions)]

    json(Dict("sets" => sets, "rank" => rank))
end
