# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: results (plot catalogue + Plotly JSON + table data)

using JSON3, CSV, DataFrames, OrderedCollections, YAML, XLSX, DuckDB, DBInterface

## Tables
function _merge_dir(study::String, run::String;
                    group::Union{String,Nothing}=nothing)
    joinpath(_run_project_dir(study, run; group), "merged")
end

function _require_duckdb(study::String, run::String;
                         group::Union{String,Nothing}=nothing)
    dir = _merge_dir(study, run; group)
    db_path = joinpath(dir, "results.duckdb")
    isfile(db_path) || return nothing
    dir
end

## Table catalogue
@get "/api/v1/studies/{study}/runs/{run}/results/tables" function(req,
                                                                    study::String,
                                                                    run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)
    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json([])

    with_results_db(dir) do con
        tables_result = DBInterface.execute(con, "SHOW TABLES")
        hidden = Set(["cluster_membership"])
        table_names = filter(n -> !(n in hidden),
                             [string(row.name) for row in eachrow(DataFrame(tables_result))])
        isempty(table_names) && return json([])

        count_sql = join(["SELECT '$(t)' AS tname, COUNT(*) AS n FROM \"$(t)\"" for t in table_names],
                         " UNION ALL ")
        count_df = DataFrame(DBInterface.execute(con, count_sql))
        row_counts = Dict(string(row.tname) => row.n for row in eachrow(count_df))

        catalog = map(table_names) do tname
            cnt         = get(row_counts, tname, 0)
            label       = replace(tname, "_" => " ") |> titlecase
            count_cols  = _sample_count_columns(con, tname)
            n_samples   = length(count_cols)
            total_reads = _sum_reads(con, tname, count_cols)
            (; id=tname, label, rows=cnt, total_reads, n_samples)
        end
        json(collect(catalog))
    end
end

## Distinct values
@post "/api/v1/studies/{study}/runs/{run}/results/tables/{table}/distinct/{column}" function(req,
                                                                            study::String,
                                                                            run::String,
                                                                            table::String,
                                                                            column::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    body = length(req.body) > 0 ? JSON3.read(String(req.body)) : (;)

    with_results_db(dir) do con
        _duckdb_distinct(con, table, column, body)
    end
end

## Table query (paginated, filtered, sorted)
@post "/api/v1/studies/{study}/runs/{run}/results/tables/{table}/query" function(req,
                                                                            study::String,
                                                                            run::String,
                                                                            table::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    body = JSON3.read(String(req.body))

    with_results_db(dir) do con
        _duckdb_paginated_query(con, table, body)
    end
end

## Filter presets
function _filters_dir()
    joinpath(dirname(ServerState.projects_dir()), "config", "filters")
end

@get "/api/v1/filter-presets" function(req)
    dir = _filters_dir()
    isdir(dir) || return json([])
    presets = map(filter(f -> endswith(f, ".yml"), readdir(dir))) do f
        path = joinpath(dir, f)
        name = splitext(f)[1]
        label = replace(name, "_" => " ") |> s -> replace(s, "." => " - ") |> titlecase
        desc = ""
        try
            lines = readlines(path)
            for line in lines
                m = match(r"^#\s*(.+)", line)
                if !isnothing(m)
                    desc = m.captures[1]
                    break
                end
            end
        catch; end
        (; name, label, file=f, description=desc)
    end
    json(presets)
end

@post "/api/v1/studies/{study}/runs/{run}/results/tables/{table}/apply-preset" function(req,
                                                                                         study::String,
                                                                                         run::String,
                                                                                         table::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    body = JSON3.read(String(req.body))
    preset_file = get(body, :preset, nothing)
    isnothing(preset_file) && return json_error(400, "missing_preset", "Body must include 'preset'")
    preset_file = string(preset_file)
    occursin(r"^[a-zA-Z0-9._-]+$", preset_file) || return json_error(400, "invalid_preset",
        "Preset name must contain only letters, numbers, dots, hyphens, and underscores")

    filter_path = joinpath(_filters_dir(), preset_file)
    isfile(filter_path) || return json_error(404, "preset_not_found",
                                                  "Preset '$preset_file' not found")

    config = YAML.load_file(filter_path)
    raw_filters = get(config, "filters", [])

    has_pipeline     = any(f -> f isa Dict && haskey(f, "pattern"), raw_filters)
    has_remove_empty = !isempty(get(config, "remove_empty", []))

    col_filters = Dict{String, Any}()
    params      = Dict{String, String}()

    if has_pipeline || has_remove_empty
        with_results_db(dir) do con
            columns = _duckdb_columns(con, table)
            col_set = Set(columns)

            ref_cols = Set{String}()
            for item in raw_filters
                (item isa Dict && haskey(item, "pattern")) || continue
                col = string(get(item, "column", ""))
                !isempty(col) && col in col_set && push!(ref_cols, col)
            end
            for col in get(config, "remove_empty", [])
                col_str = string(col)
                col_str in col_set && push!(ref_cols, col_str)
            end

            col_include = Dict{String, Set{String}}()
            for col in ref_cols
                vals_df = DataFrame(DBInterface.execute(con,
                    "SELECT DISTINCT CAST(\"$col\" AS VARCHAR) AS val FROM \"$table\" WHERE \"$col\" IS NOT NULL ORDER BY val"))
                col_include[col] = Set(string(row.val) for row in eachrow(vals_df))
            end

            for col in get(config, "remove_empty", [])
                col_str = string(col)
                haskey(col_include, col_str) || continue
                filter!(v -> !isempty(strip(v)) && lowercase(strip(v)) != "blank",
                        col_include[col_str])
            end

            for item in raw_filters
                (item isa Dict && haskey(item, "pattern")) || continue
                col       = string(get(item, "column", ""))
                pat       = string(get(item, "pattern", ""))
                action    = lowercase(string(get(item, "action", "exclude")))
                use_regex = get(item, "regex", false) == true
                (isempty(col) || isempty(pat) || !haskey(col_include, col)) && continue
                matcher = use_regex ? (v -> occursin(Regex(pat), v)) :
                                      (v -> occursin(pat, v))
                if action == "keep"
                    filter!(v -> matcher(v), col_include[col])
                else  # exclude (default)
                    filter!(v -> !matcher(v), col_include[col])
                end
            end

            for (col, vals) in col_include
                vals_vec = sort!(collect(vals))
                params["col_in.$col"] = join(vals_vec, "|")
                col_filters[col] = Dict("include" => vals_vec)
            end

            for item in raw_filters
                (item isa Dict && haskey(item, "type")) || continue
                col_str = string(get(item, "column", ""))
                isempty(col_str) && continue
                typ = string(get(item, "type", ""))
                if typ == "include"
                    vals = get(item, "values", [])
                    vals_str = [string(v) for v in vals]
                    params["col_in.$col_str"] = join(vals_str, "|")
                    col_filters[col_str] = Dict("include" => vals_str)
                elseif typ == "min"
                    val = get(item, "value", nothing)
                    isnothing(val) && continue
                    params["col_min.$col_str"] = string(val)
                    get!(col_filters, col_str, Dict{String,Any}())["min"] = val
                elseif typ == "max"
                    val = get(item, "value", nothing)
                    isnothing(val) && continue
                    params["col_max.$col_str"] = string(val)
                    get!(col_filters, col_str, Dict{String,Any}())["max"] = val
                end
            end

            rows_before = only(DataFrame(DBInterface.execute(con,
                "SELECT COUNT(*) AS n FROM \"$table\""))).n
            (where, sql_params) = _build_where(params, columns)
            rows_after = only(DataFrame(DBInterface.execute(con,
                "SELECT COUNT(*) AS n FROM \"$table\" $where", sql_params))).n
            json((; preset=preset_file, rows_before, rows_after, filters=col_filters))
        end
    else
        for item in raw_filters
            item isa Dict || continue
            col_str = string(get(item, "column", ""))
            isempty(col_str) && continue
            typ = string(get(item, "type", ""))
            if typ == "include"
                vals = get(item, "values", [])
                vals_str = [string(v) for v in vals]
                params["col_in.$col_str"] = join(vals_str, "|")
                col_filters[col_str] = Dict("include" => vals_str)
            elseif typ == "min"
                val = get(item, "value", nothing)
                isnothing(val) && continue
                params["col_min.$col_str"] = string(val)
                get!(col_filters, col_str, Dict{String,Any}())["min"] = val
            elseif typ == "max"
                val = get(item, "value", nothing)
                isnothing(val) && continue
                params["col_max.$col_str"] = string(val)
                get!(col_filters, col_str, Dict{String,Any}())["max"] = val
            end
        end

        with_results_db(dir) do con
            columns = _duckdb_columns(con, table)
            rows_before = only(DataFrame(DBInterface.execute(con,
                "SELECT COUNT(*) AS n FROM \"$table\""))).n
            (where, sql_params) = _build_where(params, columns)
            rows_after = only(DataFrame(DBInterface.execute(con,
                "SELECT COUNT(*) AS n FROM \"$table\" $where", sql_params))).n
            json((; preset=preset_file, rows_before, rows_after, filters=col_filters))
        end
    end
end

## Save filters to config/filters/
@post "/api/v1/filter-presets/{name}" function(req, name::String)
    occursin(r"^[a-zA-Z0-9._-]+$", name) || return json_error(400, "invalid_name",
        "Filter name must contain only letters, numbers, dots, hyphens, and underscores")

    dir = _filters_dir()
    mkpath(dir)
    filename = endswith(name, ".yml") ? name : name * ".yml"
    path = joinpath(dir, filename)

    body = JSON3.read(String(req.body))
    filters = get(body, :filters, nothing)
    isnothing(filters) && return json_error(400, "missing_filters", "Body must include 'filters'")
    description = get(body, :description, "Saved from WebUI")

    filter_list = OrderedDict{String,Any}[]
    for (col, f) in pairs(filters)
        col_str = string(col)
        include_vals = get(f, :include, nothing)
        min_val = get(f, :min, nothing)
        max_val = get(f, :max, nothing)

        if !isnothing(include_vals) && include_vals isa AbstractVector
            push!(filter_list, OrderedDict{String,Any}(
                "column" => col_str, "type" => "include",
                "values" => [string(v) for v in include_vals]))
        end
        if !isnothing(min_val)
            push!(filter_list, OrderedDict{String,Any}(
                "column" => col_str, "type" => "min",
                "value" => min_val))
        end
        if !isnothing(max_val)
            push!(filter_list, OrderedDict{String,Any}(
                "column" => col_str, "type" => "max",
                "value" => max_val))
        end
    end

    open(path, "w") do io
        println(io, "# ", replace(string(description), '\n' => ' '))
        YAML.write(io, Dict("filters" => filter_list))
    end

    stem = splitext(filename)[1]
    label = replace(stem, "_" => " ") |> s -> replace(s, "." => " - ") |> titlecase
    json((; name=stem, label, file=filename, description=string(description)))
end

## Save filtered table to merged directory
@post "/api/v1/studies/{study}/runs/{run}/results/tables/{table}/save" function(req,
                                                                                study::String,
                                                                                run::String,
                                                                                table::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    body = JSON3.read(String(req.body))
    save_name = get(body, :name, nothing)
    isnothing(save_name) && return json_error(400, "missing_name", "Body must include 'name'")
    save_name = string(save_name)
    occursin(r"^[a-zA-Z0-9._-]+$", save_name) || return json_error(400, "invalid_name",
        "Name must contain only letters, numbers, dots, hyphens, and underscores")

    params = _body_filter_params(body)
    sort_by  = get(params, "sort",     nothing)
    sort_dir = get(params, "sort_dir", "asc")

    df = with_results_db(dir) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return nothing
        (where, sql_params) = _build_where(params, columns)
        order = _order_clause(sort_by, sort_dir, columns)
        DataFrame(DBInterface.execute(con, "SELECT * FROM \"$table\" $where $order", sql_params))
    end

    isnothing(df) && return json_error(404, "table_not_found",
                                            "Table '$table' not found in results database")

    output_path = joinpath(dir, save_name * ".csv")
    CSV.write(output_path, df)

    with_results_db_write(dir) do con
        DBInterface.execute(con,
            "CREATE OR REPLACE TABLE \"$(save_name)\" AS SELECT * FROM read_csv_auto('$(output_path)', auto_detect=true)")
    end

    @info "Saved filtered table: $output_path ($(nrow(df)) rows)"
    json((; name=save_name, path=output_path, rows=nrow(df)))
end

## Export filtered table as Excel (.xlsx)
@post "/api/v1/studies/{study}/runs/{run}/results/tables/{table}/export" function(req,
                                                                                  study::String,
                                                                                  run::String,
                                                                                  table::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    body   = JSON3.read(String(req.body))
    params = _body_filter_params(body)
    sort_by  = get(params, "sort",     nothing)
    sort_dir = get(params, "sort_dir", "asc")

    df = with_results_db(dir) do con
        columns = _duckdb_columns(con, table)
        (where, sql_params) = _build_where(params, columns)
        order = _order_clause(sort_by, sort_dir, columns)
        DataFrame(DBInterface.execute(con,
            "SELECT * FROM \"$table\" $where $order", sql_params))
    end

    tmp = tempname() * ".xlsx"
    try
        XLSX.writetable(tmp, df)
        data = read(tmp)
        filename = string(get(body, :filename, "$(study)_$(run)_filtered.xlsx"))
        filename = replace(filename, r"[^\w._-]" => "_")  # strip unsafe chars
        HTTP.Response(200, [
            "Content-Type" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "Content-Disposition" => "attachment; filename=\"$filename\"",
        ]; body=data)
    finally
        isfile(tmp) && rm(tmp)
    end
end

## Delete a filter preset
@delete "/api/v1/filter-presets/{name}" function(req, name::String)
    occursin(r"^[a-zA-Z0-9._-]+$", name) || return json_error(400, "invalid_name",
        "Filter name must contain only letters, numbers, dots, hyphens, and underscores")
    filename = endswith(name, ".yml") ? name : name * ".yml"
    path = joinpath(_filters_dir(), filename)
    isfile(path) || return json_error(404, "preset_not_found",
                                          "Preset '$name' not found")
    rm(path)
    @info "Deleted filter preset: $path"
    json((; deleted=filename))
end

## Delete a table from merged directory
@delete "/api/v1/studies/{study}/runs/{run}/results/tables/{table}" function(req,
                                                                              study::String,
                                                                              run::String,
                                                                              table::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)
    dir = _merge_dir(study, run; group)
    path = joinpath(dir, table * ".csv")

    csv_existed = isfile(path)
    csv_existed && rm(path)

    db_dir = _require_duckdb(study, run; group)
    db_had_table = false
    if !isnothing(db_dir)
        try
            with_results_db_write(db_dir) do con
                tables_df = DataFrame(DBInterface.execute(con, "SHOW TABLES"))
                if table in string.(tables_df.name)
                    DBInterface.execute(con, "DROP TABLE \"$table\"")
                    db_had_table = true
                end
            end
        catch e
            @warn "Failed to drop DuckDB table" table exception=(e, catch_backtrace())
        end
    end

    (csv_existed || db_had_table) || return json_error(404, "table_not_found",
                                                            "Table '$table' not found")

    @info "Deleted table: $path" csv_existed db_had_table
    json((; deleted=table))
end

## OTU member lookup (JOIN cluster_membership to merged)
@get "/api/v1/studies/{study}/runs/{run}/results/otu-members/{otu}" function(req,
                                                                              study::String,
                                                                              run::String,
                                                                              otu::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    with_results_db(dir) do con
        tables = Set(string.(DataFrame(DBInterface.execute(con, "SHOW TABLES")).name))
        "cluster_membership" in tables || return json_error(404, "no_cluster_data",
                                                                  "No cluster membership data available")
        "merged" in tables || return json_error(404, "no_merged_data",
                                                     "No merged table available")

        rows = _duckdb_rows(con,
            """SELECT m.*
               FROM cluster_membership cm
               JOIN merged m ON m."SeqName" = cm."ASV"
               WHERE cm."OTU" = ?
               ORDER BY
                 regexp_extract(m."SeqName", '^[A-Za-z_]*'),
                 CASE WHEN regexp_extract(m."SeqName", '(\\d+)') = '' THEN 0
                      ELSE CAST(regexp_extract(m."SeqName", '(\\d+)') AS INTEGER) END
            """, [otu])

        columns = _duckdb_columns(con, "merged")
        json((; otu, columns, rows))
    end
end

## QC and DADA2 output discovery
@get "/api/v1/studies/{study}/runs/{run}/results/qc" function(req,
                                                               study::String,
                                                               run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)
    run_dir = _run_project_dir(study, run; group)
    report = joinpath(run_dir, "QC", "multiqc_report.html")
    has_report = isfile(report)
    run_rel = isnothing(group) ? run : joinpath(group, run)
    json((; has_report,
           report_url = has_report ? "/files/$study/runs/$run_rel/QC/multiqc_report.html" : nothing))
end

@get "/api/v1/studies/{study}/runs/{run}/results/dada2" function(req,
                                                                   study::String,
                                                                   run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)
    run_dir = _run_project_dir(study, run; group)
    run_rel = isnothing(group) ? run : joinpath(group, run)

    fig_order = ["quality_unfiltered", "quality_filtered", "error_rates",
                 "length_distribution", "length_distribution_filtered"]
    fig_dir = joinpath(run_dir, "dada2", "Figures")
    figures = if isdir(fig_dir)
        available = Set(splitext(f)[1] for f in readdir(fig_dir) if endswith(f, ".pdf"))
        ordered = filter(n -> n in available, fig_order)
        extras = sort(collect(setdiff(available, Set(fig_order))))
        map(vcat(ordered, extras)) do name
            label = replace(name, "_" => " ") |> titlecase
            url = "/files/$study/runs/$run_rel/dada2/Figures/$name.pdf"
            (; name, label, url)
        end
    else
        []
    end

    stats_csv = joinpath(run_dir, "dada2", "Tables", "pipeline_stats.csv")
    has_stats = isfile(stats_csv)

    log_dir = joinpath(run_dir, "dada2", "Logs")
    logs = if isdir(log_dir)
        map(sort(readdir(log_dir))) do f
            url = "/files/$study/runs/$run_rel/dada2/Logs/$f"
            (; name=f, url)
        end
    else
        []
    end

    config_path = joinpath(run_dir, "run_config.yml")
    dada2_config = if isfile(config_path)
        cfg = YAML.load_file(config_path)
        d2 = get(cfg, "dada2", Dict())
        d2 isa Dict || (d2 = Dict())
        config = Dict{String,Any}()
        for key in ("file_patterns", "filter_trim", "dada", "merge", "asv", "taxonomy")
            haskey(d2, key) && (config[key] = d2[key])
        end
        if haskey(config, "taxonomy")
            delete!(config["taxonomy"], "multithread")
            delete!(config["taxonomy"], "remote")
        end
        config
    else
        Dict{String,Any}()
    end

    json((; figures, has_stats, logs, config=dada2_config))
end

## DADA2 pipeline stats as table data
@get "/api/v1/studies/{study}/runs/{run}/results/dada2/stats" function(req,
                                                                        study::String,
                                                                        run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)
    stats_path = joinpath(_run_project_dir(study, run; group), "dada2", "Tables", "pipeline_stats.csv")
    isfile(stats_path) || return json_error(404, "not_found", "No pipeline stats found")

    df = CSV.read(stats_path, DataFrame)
    columns = names(df)
    rows = [OrderedDict(c => (ismissing(row[c]) ? nothing : row[c]) for c in columns)
            for row in eachrow(df)]
    json((; columns, rows))
end

@get "/api/v1/studies/{study}/runs/{run}/results/otu-counts" function(req,
                                                                       study::String,
                                                                       run::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                     "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    group = _req_group(req)

    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return json_error(404, "no_results",
                                             "No results database for run '$run' - run the pipeline first")

    with_results_db(dir) do con
        tables = Set(string.(DataFrame(DBInterface.execute(con, "SHOW TABLES")).name))
        "cluster_membership" in tables || return json((; counts=Dict{String,Int}()))

        df = DataFrame(DBInterface.execute(con,
            """SELECT "OTU", COUNT(*) AS n FROM cluster_membership GROUP BY "OTU" """))
        counts = Dict(string(row.OTU) => row.n for row in eachrow(df))
        json((; counts))
    end
end
