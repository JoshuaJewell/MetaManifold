# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: on-demand analysis (alpha diversity, taxa bars, pipeline stats, NMDS, PERMANOVA)

using CSV, DataFrames

using MetaManifold.Analysis: alpha_chart, taxa_bar_chart, pipeline_stats_chart,
                             sample_columns, taxonomy_levels, taxon_column, filtered_counts,
                             aggregate_by_taxon, combined_counts_across_runs,
                             alpha_boxplot, nmds_chart, run_nmds, run_permanova, r_available,
                             sequence_column_name, normalise_counts, venn_taxa_present,
                             pool_columns, auto_min_depth

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
    source = haskey(body, :source) ? string(get(body, :source)) : nothing
    params = _body_filter_params(body)
    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    include_contamination = _analysis_include_contamination(study; run, group, config_cache=cfg_cache)
    (norm_method, norm_depth) = _analysis_normalisation(study; run, group, config_cache=cfg_cache)

    prefix = let p = get(body, :prefix, nothing); isnothing(p) ? nothing : string(p) end

    _with_analysis_annotation_table(study, run, table; group, requested_source=source) do con, _, columns
        scols = _filter_by_prefix(sample_columns(con, table), prefix)
        isempty(scols) && return json_error(400, "no_samples", "No sample columns found in table '$table'")
        where_clause, where_params = _analysis_where_clause(params, columns; include_contamination)
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

## Per-run taxa bar chart
@post "/api/v1/studies/{study}/runs/{run}/analysis/taxa-bar" function(req,
                                                                       study::String,
                                                                       run::String)
    group = _req_group(req)
    dir, err = _require_run_results(study, run; group)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    table = get(body, :table, "merged")
    source = haskey(body, :source) ? string(get(body, :source)) : nothing
    rank = get(body, :rank, nothing)
    top_n = get(body, :top_n, 15)
    relative = get(body, :relative, true)
    do_pool = Bool(get(body, :pool, false))
    pool_groups = let v = get(body, :pool_groups, nothing)
        isnothing(v) ? String[] : String[string(g) for g in v]
    end
    prefix = let p = get(body, :prefix, nothing); isnothing(p) ? nothing : string(p) end
    params = _body_filter_params(body)
    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    include_contamination = _analysis_include_contamination(study; run, group, config_cache=cfg_cache)
    (norm_method, norm_depth) = _analysis_normalisation(study; run, group, config_cache=cfg_cache)

    _with_analysis_annotation_table(study, run, table; group, requested_source=source) do con, _, columns
        scols = _filter_by_prefix(sample_columns(con, table), prefix)
        isempty(scols) && return json_error(400, "no_samples", "No sample columns found")
        where_clause, where_params = _analysis_where_clause(params, columns; include_contamination)

        if isnothing(rank)
            levels = taxonomy_levels(con, table)
            isempty(levels) && return json_error(400, "no_taxonomy", "No taxonomy columns found")
            rank = last(levels)
        end

        rank_col = taxon_column(columns, string(rank))
        agg = aggregate_by_taxon(con, table, scols, rank_col, where_clause, where_params)
        nrow(agg) == 0 && return json_error(400, "no_data", "No data after filtering")

        taxon_labels = String.(agg.taxon)
        counts_taxa_x_samples = Matrix{Float64}(agg[:, scols])

        # normalise_counts expects samples x features as a concrete Matrix; `'`
        # returns a lazy LinearAlgebra.Adjoint which fails the strict signature,
        # so materialise both transposes with permutedims.
        counts_t = permutedims(counts_taxa_x_samples)
        norm_result = normalise_counts(counts_t; method=norm_method,
                                       depth=norm_depth, seed=_study_seed(study))
        scols = scols[norm_result.kept]
        isempty(scols) && return json_error(400, "no_samples",
                                            "All samples dropped below normalisation depth")
        counts = permutedims(norm_result.mat)  # back to taxa x samples

        if do_pool
            scols, counts = pool_columns(scols, counts, pool_groups;
                                         fallback_label=something(prefix, run))
        end

        fig = taxa_bar_chart(taxon_labels, scols, counts; top_n=Int(top_n), relative=Bool(relative))
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
    source = get(HTTP.queryparams(req), "source", nothing)
    _with_analysis_annotation_table(study, run, table; group, requested_source=source) do con, _, _
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

function _analysis_include_contamination(study::String;
                                         run::Union{String,Nothing}=nothing,
                                         group::Union{String,Nothing}=nothing,
                                         config_cache::Union{Dict,Nothing}=nothing)
    key = (study, something(run, ""), something(group, ""))
    resolved = if !isnothing(config_cache) && haskey(config_cache, key)
        config_cache[key]
    else
        cfg = _resolve_config(study, run, group)
        !isnothing(config_cache) && (config_cache[key] = cfg)
        cfg
    end
    entry = get(resolved, "analysis.include_contamination", (; value=false, source="default"))
    Bool(get(entry, :value, false))
end

function _analysis_normalisation(study::String;
                                  run::Union{String,Nothing}=nothing,
                                  group::Union{String,Nothing}=nothing,
                                  config_cache::Union{Dict,Nothing}=nothing)
    key = (study, something(run, ""), something(group, ""))
    resolved = if !isnothing(config_cache) && haskey(config_cache, key)
        config_cache[key]
    else
        cfg = _resolve_config(study, run, group)
        !isnothing(config_cache) && (config_cache[key] = cfg)
        cfg
    end
    method_entry = get(resolved, "analysis.normalisation",       (; value="none", source="default"))
    depth_entry  = get(resolved, "analysis.normalisation_depth", (; value=0,      source="default"))
    method = String(get(method_entry, :value, "none"))
    depth  = Int(get(depth_entry,  :value, 0))
    (method, depth)
end

function _resolve_analysis_source(study::String, run::String, table::String;
                                  group::Union{String,Nothing}=nothing,
                                  requested_source::Union{String,Nothing}=nothing)
    sources = isnothing(requested_source) ? ("DADA2", "VSEARCH") : (requested_source,)
    for source in sources
        ann_db = _annotation_db_path(study, run, source; group)
        isfile(ann_db) || continue
        found = _with_annotation_db(study, run, source; group) do con
            table in String.(DataFrame(DBInterface.execute(con, "SHOW TABLES")).name)
        end
        found === true && return source
    end
    nothing
end

function _resolve_analysis_source_with_sequence(study::String, run::String, table::String;
                                                group::Union{String,Nothing}=nothing,
                                                requested_source::Union{String,Nothing}=nothing)
    sources = if isnothing(requested_source)
        ("DADA2", "VSEARCH")
    else
        requested_source == "DADA2" ? ("DADA2", "VSEARCH") : (requested_source, "DADA2")
    end
    table_found_without_sequence = false

    for source in sources
        ann_db = _annotation_db_path(study, run, source; group)
        isfile(ann_db) || continue
        result = _with_annotation_db(study, run, source; group) do con
            columns = _duckdb_columns(con, table)
            isempty(columns) && return (:missing, nothing)
            seq_col = sequence_column_name(columns)
            isnothing(seq_col) && return (:present_without_sequence, nothing)
            (:ok, source)
        end
        result == (:ok, source) && return source, false, false
        result == (:present_without_sequence, nothing) && (table_found_without_sequence = true)
    end

    if table_found_without_sequence
        return nothing, true, false
    end
    nothing, false, true
end

function _analysis_where_clause(params, columns::Vector{String};
                                include_contamination::Bool=false)
    where_clause, where_params = _build_where(params, columns)
    if !include_contamination && "Contamination" in columns
        contam_clause = "COALESCE(LOWER(TRIM(\"Contamination\")), '') != 'yes'"
        where_clause = isempty(where_clause) ? "WHERE $contam_clause" : "$where_clause AND $contam_clause"
    end
    where_clause, where_params
end

function _with_analysis_annotation_table(f::Function, study::String, run::String, table::String;
                                         group::Union{String,Nothing}=nothing,
                                         requested_source::Union{String,Nothing}=nothing)
    source = _resolve_analysis_source(study, run, table; group, requested_source)
    isnothing(source) && return json_error(
        404, "no_annotation_table",
        isnothing(requested_source) ?
            "Analysis requires an annotated '$table' table. Generate annotations first." :
            "Analysis requires annotated '$table' data for source '$requested_source'."
    )

    _with_annotation_db(study, run, source; group) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return json_error(404, "table_not_found",
                                              "Annotated table '$table' not found")
        f(con, source, columns)
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

function _expand_comparison_run_specs(study::String, runs_spec)
    expanded = NamedTuple[]
    for spec in runs_spec
        run_name = string(get(spec, :run, ""))
        isempty(run_name) && continue
        group  = _opt_string(spec, :group)
        prefix = _opt_string(spec, :prefix)
        source = _opt_string(spec, :source)

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

function _collect_cross_run_asvs(study::String, runs_spec, table, params)
    run_data = Tuple{String, Vector{String}, DataFrame}[]
    group_labels = String[]
    run_labels = String[]
    missing_seq = false
    missing_annotation = false
    cfg_cache = Dict{Tuple{String,String,String}, Any}()

    for spec in _expand_comparison_run_specs(study, runs_spec)
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && continue
        source, source_missing_seq, source_missing_annotation = _resolve_analysis_source_with_sequence(
            study, resolved.run, table; group=resolved.group, requested_source=resolved.source)
        if isnothing(source)
            missing_seq |= source_missing_seq
            missing_annotation |= source_missing_annotation
            continue
        end
        include_contamination = _analysis_include_contamination(study; run=resolved.run, group=resolved.group, config_cache=cfg_cache)
        _with_annotation_db(study, resolved.run, source; group=resolved.group) do con
            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return

            columns = _duckdb_columns(con, table)
            seq_col = sequence_column_name(columns)
            if isnothing(seq_col)
                missing_seq = true
                return
            end

            where_clause, where_params = _analysis_where_clause(params, columns; include_contamination)
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

    run_data, group_labels, run_labels, missing_seq, missing_annotation
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

    expanded_specs = _expand_comparison_run_specs(study, runs_spec)
    resolved_specs = filter(!isnothing, [_resolve_run_duckdb(study, spec) for spec in expanded_specs])
    isempty(resolved_specs) && return json_error(400, "no_data", "No data found for any run")

    compare_mode = length(unique(_resolved_run_label(r) for r in resolved_specs)) > 1 ? :run : :subgroup
    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    (norm_method, norm_depth_cfg) = _analysis_normalisation(study)

    # First pass: collect raw matrices (fetched inside annotation DB closures)
    collected = Tuple{Matrix{Float64}, Vector{String}, Any}[]
    for resolved in resolved_specs
        source = _resolve_analysis_source(study, resolved.run, table; group=resolved.group,
                                          requested_source=resolved.source)
        isnothing(source) && continue
        include_contamination = _analysis_include_contamination(study; run=resolved.run,
                                                                group=resolved.group,
                                                                config_cache=cfg_cache)
        _with_annotation_db(study, resolved.run, source; group=resolved.group) do con
            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return
            columns = _duckdb_columns(con, table)
            where_clause, where_params = _analysis_where_clause(params, columns; include_contamination)
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
    (norm_method, norm_depth) = _analysis_normalisation(study)

    run_data, group_labels, run_name_labels, missing_seq, missing_annotation = _collect_cross_run_asvs(study, runs_spec, table, params)

    missing_annotation && return json_error(404, "no_annotation_table",
                                            "NMDS requires annotated '$table' tables for the selected runs")
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
    (norm_method, norm_depth) = _analysis_normalisation(study)

    run_data, group_labels, run_labels, missing_seq, missing_annotation = _collect_cross_run_asvs(study, runs_spec, table, params)

    missing_annotation && return json_error(404, "no_annotation_table",
                                            "PERMANOVA requires annotated '$table' tables for the selected runs")
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

## Cross-run taxa bar chart (pooled by run / subgroup)
@post "/api/v1/studies/{study}/analysis/taxa-bar" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    body = JSON3.read(String(req.body))
    runs_spec = get(body, :runs, [])
    isempty(runs_spec) && return json_error(400, "no_runs", "Provide at least one run")
    table    = string(get(body, :table, "merged"))
    rank     = let r = get(body, :rank, nothing); isnothing(r) ? nothing : string(r) end
    top_n    = Int(get(body, :top_n, 15))
    relative = Bool(get(body, :relative, true))
    params   = _body_filter_params(body)
    (norm_method, norm_depth_cfg) = _analysis_normalisation(study)
    cfg_cache = Dict{Tuple{String,String,String}, Any}()

    # Collect per-run aggregated counts.
    collected = Tuple{String, Vector{String}, DataFrame}[]
    for spec in runs_spec
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && continue
        source = _resolve_analysis_source(study, resolved.run, table;
                                          group=resolved.group,
                                          requested_source=resolved.source)
        isnothing(source) && continue
        include_contamination = _analysis_include_contamination(study;
            run=resolved.run, group=resolved.group, config_cache=cfg_cache)
        _with_analysis_annotation_table(study, resolved.run, table;
            group=resolved.group, requested_source=source) do con, _, columns
            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return nothing
            where_clause, where_params = _analysis_where_clause(params, columns; include_contamination)

            r = if isnothing(rank)
                levels = taxonomy_levels(con, table)
                isempty(levels) && return nothing
                last(levels)
            else
                rank
            end
            rank_col = taxon_column(columns, string(r))
            agg = aggregate_by_taxon(con, table, scols, rank_col, where_clause, where_params)
            nrow(agg) == 0 && return nothing
            label = _resolved_group_label(resolved)
            push!(collected, (label, scols, agg))
            nothing
        end
    end

    isempty(collected) && return json_error(400, "no_data", "No data found for any run")

    # Combine across runs via the existing helper.
    mat, all_samples, taxa_labels, run_labels = combined_counts_across_runs(collected)

    # Normalise (samples x taxa stays samples x taxa).
    norm_depth = _resolve_cross_run_depth(norm_method, norm_depth_cfg, (mat,))
    seed = _study_seed(study)
    (; mat, kept) = normalise_counts(mat; method=norm_method, depth=norm_depth, seed)
    all_samples  = all_samples[kept]
    run_labels   = run_labels[kept]
    isempty(kept) && return json_error(400, "no_samples",
                                            "All samples dropped below normalisation depth")

    # Transpose to taxa x samples, then pool by run label.
    counts = permutedims(mat)  # taxa x samples
    unique_labels = unique(run_labels)
    scols, counts = pool_columns(all_samples, counts, unique_labels)

    fig = taxa_bar_chart(taxa_labels, scols, counts; top_n, relative)
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
    conditions = NamedTuple{
        (:group, :run, :prefix, :taxa),
        Tuple{Union{String,Nothing}, String, Union{String,Nothing}, Vector{String}}
    }[]
    cfg_cache  = Dict{Tuple{String,String,String}, Any}()
    missing_annotation = false

    for spec in _expand_comparison_run_specs(study, runs_spec)
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && continue

        source = _resolve_analysis_source(study, resolved.run, table;
                                          group=resolved.group,
                                          requested_source=resolved.source)
        if isnothing(source)
            missing_annotation = true
            continue
        end

        include_contamination = _analysis_include_contamination(
            study; run=resolved.run, group=resolved.group, config_cache=cfg_cache)

        _with_annotation_db(study, resolved.run, source; group=resolved.group) do con
            columns = _duckdb_columns(con, table)
            isempty(columns) && return

            levels = taxonomy_levels(con, table)
            isempty(levels) && return
            effective_rank = rank in levels ? rank : last(levels)
            rank_col = taxon_column(columns, effective_rank)

            scols = _filter_by_prefix(sample_columns(con, table), resolved.prefix)
            isempty(scols) && return

            where_clause, where_params = _analysis_where_clause(params, columns;
                                                                include_contamination)
            taxa = venn_taxa_present(con, table, scols, rank_col,
                                     where_clause, where_params)
            push!(conditions, (; group=resolved.group, run=resolved.run,
                                  prefix=resolved.prefix, taxa))
        end
    end

    if isempty(conditions) && missing_annotation
        return json_error(404, "no_annotation_table",
            "No annotated '$table' table found for the selected runs")
    end
    length(conditions) < 2 && return json_error(400, "too_few_conditions",
        "Need data from at least 2 conditions for the taxon overlap diagram")

    labels = _venn_condition_labels(conditions)
    sets = [(; name=labels[i], taxa=conditions[i].taxa) for i in eachindex(conditions)]

    json(Dict("sets" => sets, "rank" => rank))
end
