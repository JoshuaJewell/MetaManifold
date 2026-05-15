# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: organism composition - category-based classification of ASVs/OTUs
# for relative abundance analysis across broad organism groups.
using JSON3, CSV, DataFrames, OrderedCollections, DuckDB, DBInterface, YAML

const _COMPOSITION_TABLE = "composition"

# Columns to drop from the merged table depending on the selected source.
# Mirrors the logic in FuncDBAnnotation.annotate_table (funcdb.jl).
function _source_drop_cols(source::String, merged_cols::Vector{String})
    if source == "VSEARCH"
        filter(c -> endswith(c, "_dada2") || endswith(c, "_boot"), merged_cols)
    else  # DADA2
        vsearch_only = Set([
            "Pident", "Accession", "rRNA", "Organellum", "specimen",
            "Domain", "Supergroup", "Division", "Subdivision", "Class", "Order",
            "Family", "Genus", "Species",
        ])
        filter(c -> c in vsearch_only, merged_cols)
    end
end

"""
    _taxonomy_cols_for_source(source, merged_cols) -> Vector{String}

Return the taxonomy column names present in `merged_cols` for the given source.
"""
function _taxonomy_cols_for_source(source::String, merged_cols_set::Set{String})
    cols = String[]
    for r in FuncDBAnnotation.RANK_HIERARCHY
        col = source == "VSEARCH" ? r.vsearch : r.dada2
        col in merged_cols_set && push!(cols, col)
    end
    # Also include Subdivision (not in RANK_HIERARCHY but present in merged)
    sub_col = source == "VSEARCH" ? "Subdivision" : "Subdivision_dada2"
    sub_col in merged_cols_set && push!(cols, sub_col)
    # Include Domain for DADA2
    if source == "DADA2"
        "Domain_dada2" in merged_cols_set && push!(cols, "Domain_dada2")
    end
    unique(cols)
end

"""
    _build_quality_where(source, merged_cols_set; omit_na, max_x) -> String

Build a SQL WHERE clause fragment that filters out low-quality taxonomy rows.

- `omit_na`: remove rows where ALL taxonomy columns for this source are NA/empty/blank.
- `max_x`: remove rows where more than this many taxonomy columns contain only
  unresolved placeholders (values ending in `_X` or equal to `X`). Set to -1 to disable.
"""
function _build_quality_where(source::String, merged_cols_set::Set{String};
                              omit_na::Bool=false, max_x::Int=-1)
    clauses = String[]
    tax_cols = _taxonomy_cols_for_source(source, merged_cols_set)
    isempty(tax_cols) && return ""

    if omit_na
        # At least one taxonomy column must have a real value
        or_parts = ["""(m."$c" IS NOT NULL AND TRIM(CAST(m."$c" AS VARCHAR)) != '' AND LOWER(TRIM(CAST(m."$c" AS VARCHAR))) NOT IN ('na', 'blank'))""" for c in tax_cols]
        push!(clauses, "(" * join(or_parts, " OR ") * ")")
    end

    if max_x >= 0
        # Count total _X placeholders across all taxonomy columns for this row.
        # Each column can contribute multiple _X segments (e.g. "Eukaryota_X_X_X" has 3).
        # We count by measuring how much shorter the string gets when _X is removed.
        # Also count NULL/empty/NA columns as having all-unresolved content (= 1 X each).
        x_checks = String[]
        for c in tax_cols
            push!(x_checks, """CASE
                WHEN m."$c" IS NULL OR TRIM(CAST(m."$c" AS VARCHAR)) = '' OR LOWER(TRIM(CAST(m."$c" AS VARCHAR))) = 'na'
                    THEN 1
                ELSE (LENGTH(CAST(m."$c" AS VARCHAR)) - LENGTH(REPLACE(CAST(m."$c" AS VARCHAR), '_X', ''))) / 2
            END""")
        end
        count_expr = join(x_checks, " + ")
        push!(clauses, "($count_expr) <= $max_x")
    end

    isempty(clauses) ? "" : "WHERE " * join(clauses, " AND ")
end

## Helpers
function _compositions_dir()
    joinpath(dirname(ServerState.projects_dir()), "config", "compositions")
end

function _composition_dir(study::String, run::String, source::String;
                          group::Union{String,Nothing}=nothing)
    joinpath(_run_project_dir(study, run; group), "composition", source)
end

function _composition_db_path(study::String, run::String, source::String;
                              group::Union{String,Nothing}=nothing)
    joinpath(_composition_dir(study, run, source; group), "composition.duckdb")
end

## Category set loading
function _load_category_set(name::String)
    dir = _compositions_dir()
    isdir(dir) || return nothing
    path = joinpath(dir, name * ".yml")
    isfile(path) || return nothing
    YAML.load_file(path)
end

function _list_category_sets()
    dir = _compositions_dir()
    isdir(dir) || return []
    sets = Dict{String,Any}[]
    for f in sort(readdir(dir))
        endswith(f, ".yml") || endswith(f, ".yaml") || continue
        config = try YAML.load_file(joinpath(dir, f)) catch; continue end
        cs = get(config, "categories", [])
        cats = [Dict("name" => get(c, "name", ""), "colour" => get(c, "colour", nothing))
                for c in cs]
        push!(sets, Dict(
            "name"        => f[1:end - (endswith(f, ".yaml") ? 5 : 4)],
            "label"       => get(config, "name", f),
            "description" => get(config, "description", ""),
            "categories"  => cats,
        ))
    end
    sets
end

## Filter to SQL translation

# Build a mapping from VSEARCH column names (used in filter YAMLs) to the actual
# column names for the selected source. For VSEARCH this is identity; for DADA2
# taxonomy columns become their _dada2 equivalents.
function _col_translate_map(source::String)
    map = Dict{String,String}()
    for r in FuncDBAnnotation.RANK_HIERARCHY
        map[r.vsearch] = source == "VSEARCH" ? r.vsearch : r.dada2
    end
    # Subdivision is not in RANK_HIERARCHY but exists in merged tables
    map["Subdivision"] = source == "VSEARCH" ? "Subdivision" : "Subdivision_dada2"
    map
end

"""
    _filter_to_sql_conditions(filter_config, col_set, table_alias; col_map) -> Vector{String}

Translate a filter YAML config (from config/filters/) into SQL condition fragments.
All conditions within a single filter are AND'd together.
`col_set` is a Set of available columns (for validation).
`table_alias` is the SQL alias prefix (e.g. "m" for merged table).
`col_map` translates filter column names to actual table column names (for source-awareness).
"""
function _filter_to_sql_conditions(filter_config::Dict, col_set::Set{String},
                                   table_alias::String;
                                   col_map::Dict{String,String}=Dict{String,String}())
    _xlate(c) = get(col_map, c, c)  # translate column name through map

    conditions = String[]
    raw_filters = get(filter_config, "filters", [])

    # remove_empty conditions
    for col in get(filter_config, "remove_empty", [])
        col_str = _xlate(string(col))
        col_str in col_set || continue
        push!(conditions,
            """($table_alias."$col_str" IS NOT NULL AND TRIM(CAST($table_alias."$col_str" AS VARCHAR)) != '' AND LOWER(TRIM(CAST($table_alias."$col_str" AS VARCHAR))) != 'blank')""")
    end

    for item in raw_filters
        item isa Dict || continue

        # Pattern-based rules
        if haskey(item, "pattern")
            col = _xlate(string(get(item, "column", "")))
            isempty(col) && continue
            col in col_set || continue
            pat = string(get(item, "pattern", ""))
            isempty(pat) && continue
            action = lowercase(string(get(item, "action", "exclude")))
            use_regex = get(item, "regex", false) == true

            if use_regex
                match_expr = "REGEXP_MATCHES(CAST($table_alias.\"$col\" AS VARCHAR), '$(pat)')"
            else
                match_expr = "CAST($table_alias.\"$col\" AS VARCHAR) LIKE '%$(pat)%'"
            end

            if action == "keep"
                push!(conditions, match_expr)
            else  # exclude
                push!(conditions, "NOT ($match_expr)")
            end

        # Type-based rules (min/max/include)
        elseif haskey(item, "type")
            col = _xlate(string(get(item, "column", "")))
            isempty(col) && continue
            col in col_set || continue
            typ = string(get(item, "type", ""))
            if typ == "min"
                val = get(item, "value", nothing)
                isnothing(val) && continue
                push!(conditions, "TRY_CAST($table_alias.\"$col\" AS DOUBLE) >= $val")
            elseif typ == "max"
                val = get(item, "value", nothing)
                isnothing(val) && continue
                push!(conditions, "TRY_CAST($table_alias.\"$col\" AS DOUBLE) <= $val")
            elseif typ == "include"
                vals = get(item, "values", [])
                isempty(vals) && continue
                val_list = join(["'$(string(v))'" for v in vals], ", ")
                push!(conditions, "CAST($table_alias.\"$col\" AS VARCHAR) IN ($val_list)")
            end
        end
    end

    conditions
end

"""
    _build_category_case_when(categories, merged_col_set, ann_col_set, source) -> String

Build a SQL CASE WHEN expression that classifies each row into a category.
Filter column names are translated to the correct source columns (VSEARCH or DADA2).
"""
function _build_category_case_when(categories::Vector, merged_col_set::Set{String},
                                   ann_col_set::Set{String}, source::String)
    filters_dir = _filters_dir()
    col_map = _col_translate_map(source)
    branches = String[]

    for cat in categories
        cat_name = get(cat, "name", "")
        isempty(cat_name) && continue

        filter_file = get(cat, "filter", nothing)
        isnothing(filter_file) && continue  # catch-all handled by ELSE

        filter_path = joinpath(filters_dir, string(filter_file))
        isfile(filter_path) || continue

        filter_config = try YAML.load_file(filter_path) catch; continue end
        conditions = _filter_to_sql_conditions(filter_config, merged_col_set, "m"; col_map)

        # funcdb_require: additional conditions on annotation columns
        funcdb_req = get(cat, "funcdb_require", nothing)
        if !isnothing(funcdb_req) && funcdb_req isa Dict
            for (col, val) in funcdb_req
                col_str = string(col)
                val_str = string(val)
                if col_str in ann_col_set
                    push!(conditions, "COALESCE(ann.\"$col_str\", '') = '$val_str'")
                else
                    # Column not available in annotations -> condition can't match
                    push!(conditions, "1 = 0")
                end
            end
        end

        isempty(conditions) && continue
        branch = "WHEN (" * join(conditions, " AND ") * ") THEN '$(cat_name)'"
        push!(branches, branch)
    end

    if isempty(branches)
        return "'Unassigned'"
    end

    "CASE\n    " * join(branches, "\n    ") * "\n    ELSE 'Unassigned'\nEND"
end

## Composition DuckDB management
function _with_composition_db(f, study::String, run::String, source::String;
                              group::Union{String,Nothing}=nothing, readonly::Bool=true)
    db_path = _composition_db_path(study, run, source; group)
    isfile(db_path) || return json_error(404, "no_composition",
        "No composition table found. Build one first.")
    db = DuckDB.DB(db_path; readonly)
    con = DBInterface.connect(db)
    try
        f(con)
    finally
        DBInterface.close!(con)
        close(db)
    end
end

## Build composed view

# Annotation columns to bring into the composed view (FuncDB output + user edits).
const _ANNOTATION_CARRY_COLS = [
    "Contamination", "BLAST Assignment",
    "function", "detailed_function", "assoc_organism", "assoc_material",
    "environment", "human_pathogen", "comment", "reference",
]

function _build_composition!(study::String, run::String, source::String,
                             merged_table::String, category_set_name::String;
                             group::Union{String,Nothing}=nothing,
                             max_x::Int=-1)
    merge_dir = _require_duckdb(study, run; group)
    isnothing(merge_dir) && return json_error(404, "no_results",
        "No results database for run '$run' - run the pipeline first")

    cat_config = _load_category_set(category_set_name)
    isnothing(cat_config) && return json_error(404, "category_set_not_found",
        "Category set '$category_set_name' not found")
    categories = get(cat_config, "categories", [])

    # 1. Discover merged table columns
    merged_cols = with_results_db(merge_dir) do con
        _duckdb_columns(con, merged_table)
    end
    merged_cols isa HTTP.Response && return merged_cols
    isempty(merged_cols) && return json_error(404, "table_not_found",
        "Table '$merged_table' not found in results database")
    merged_col_set = Set(merged_cols)

    # 2. Check if annotation DB exists; discover available annotation tables
    ann_db_path = abspath(_annotation_db_path(study, run, source; group))
    has_annotations = isfile(ann_db_path)
    ann_cols = String[]
    ann_table = ""

    if has_annotations
        try
            db = DuckDB.DB(ann_db_path; readonly=true)
            con = DBInterface.connect(db)
            try
                # Find the best annotation table: prefer one matching the merged table,
                # otherwise pick the first available table in the annotation DB.
                available_tables = String[string(r.table_name)
                    for r in eachrow(DataFrame(DBInterface.execute(con,
                        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'")))]
                if merged_table in available_tables
                    ann_table = merged_table
                elseif !isempty(available_tables)
                    ann_table = first(available_tables)
                end
                if !isempty(ann_table)
                    ann_cols = _duckdb_columns(con, ann_table)
                end
            catch
                ann_cols = String[]
            finally
                DBInterface.close!(con)
                close(db)
            end
        catch
            ann_cols = String[]
        end
    end
    ann_col_set = Set(ann_cols)
    has_ann_table = !isempty(ann_cols)

    # 3. Strip columns from the other taxonomy source
    drop_cols = Set(_source_drop_cols(source, merged_cols))
    keep_cols = filter(c -> !(c in drop_cols), merged_cols)
    merged_select = join(["m.\"$c\"" for c in keep_cols], ", ")

    # 4. Build the CASE WHEN (source-aware: translates filter column names)
    case_when = _build_category_case_when(categories, merged_col_set, ann_col_set, source)

    # 5. Build quality filter WHERE clause (always omit NA, optional max X)
    quality_where = _build_quality_where(source, merged_col_set; omit_na=false, max_x)

    # 6. Build the carry columns (only those that actually exist in annotation)
    carry_cols = filter(c -> c in ann_col_set, _ANNOTATION_CARRY_COLS)

    # 7. Build and execute the composed query
    comp_dir = _composition_dir(study, run, source; group)
    mkpath(comp_dir)
    db_path = _composition_db_path(study, run, source; group)
    rm(db_path; force=true)  # fresh build

    results_db_path = abspath(joinpath(merge_dir, "results.duckdb"))
    total_rows = 0
    total_reads = 0
    cat_stats = OrderedDict{String,Any}()

    # We attach both DBs from a fresh DuckDB instance
    comp_db = DuckDB.DB(db_path)
    comp_con = DBInterface.connect(comp_db)
    try
        DBInterface.execute(comp_con,
            "ATTACH '$(results_db_path)' AS results_db (READ_ONLY)")

        if has_ann_table
            DBInterface.execute(comp_con,
                "ATTACH '$(ann_db_path)' AS ann_db (READ_ONLY)")
        end

        carry_select = isempty(carry_cols) ? "" :
            ", " * join(["ann.\"$c\"" for c in carry_cols], ", ")

        if has_ann_table
            sql = """
                CREATE TABLE "$_COMPOSITION_TABLE" AS
                SELECT $merged_select$carry_select,
                       $case_when AS "Category"
                FROM results_db."$merged_table" m
                LEFT JOIN ann_db."$ann_table" ann ON m."SeqName" = ann."SeqName"
                $quality_where
            """
        else
            sql = """
                CREATE TABLE "$_COMPOSITION_TABLE" AS
                SELECT $merged_select,
                       $case_when AS "Category"
                FROM results_db."$merged_table" m
                $quality_where
            """
        end

        DBInterface.execute(comp_con, sql)

        # 8. Collect summary with read counts
        count_cols = _sample_count_columns(comp_con, _COMPOSITION_TABLE)
        reads_sum = isempty(count_cols) ? "0" :
            join(["COALESCE(SUM(\"$c\"), 0)" for c in count_cols], " + ")

        summary_df = DataFrame(DBInterface.execute(comp_con,
            """SELECT "Category",
                      COUNT(*) AS rows,
                      ($reads_sum) AS reads
               FROM "$_COMPOSITION_TABLE"
               GROUP BY "Category"
               ORDER BY "Category" """))

        total_rows = sum(summary_df.rows; init=0)
        total_reads = sum(summary_df.reads; init=0)

        cat_stats = OrderedDict{String,Any}()
        for row in eachrow(summary_df)
            cat_stats[string(row.Category)] = Dict(
                "rows"          => Int(row.rows),
                "reads"         => Int(row.reads),
                "reads_percent" => total_reads > 0 ?
                    round(100.0 * row.reads / total_reads; digits=2) : 0.0,
            )
        end

    finally
        try DBInterface.execute(comp_con, "DETACH results_db") catch end
        try DBInterface.execute(comp_con, "DETACH ann_db") catch end
        DBInterface.close!(comp_con)
        close(comp_db)
    end

    json(Dict(
        "table"        => _COMPOSITION_TABLE,
        "source"       => source,
        "category_set" => category_set_name,
        "total_rows"   => total_rows,
        "total_reads"  => total_reads,
        "categories"   => cat_stats,
    ))
end

## Composition analysis (stacked bar chart)
function _composition_chart(con, table::String, category_set_config::Dict;
                            prefix::Union{String,Nothing}=nothing,
                            do_pool::Bool=false,
                            pool_groups::Vector{String}=String[])
    scols = _filter_by_prefix(Analysis.sample_columns(con, table), prefix)
    isempty(scols) && return json_error(400, "no_samples", "No sample columns found")

    categories_cfg = get(category_set_config, "categories", [])
    cat_names = [get(c, "name", "") for c in categories_cfg]
    # Always append the catch-all bucket so taxa matching no category remain represented
    push!(cat_names, "Unassigned")
    colour_map = Dict{String,String}()
    for c in categories_cfg
        clr = get(c, "colour", nothing)
        !isnothing(clr) && (colour_map[get(c, "name", "")] = string(clr))
    end
    colour_map["Unassigned"] = "#95a5a6"

    # Aggregate sample counts by Category
    sum_exprs = join(["SUM(COALESCE(\"$c\", 0)) AS \"$c\"" for c in scols], ", ")
    agg_df = DataFrame(DBInterface.execute(con,
        """SELECT "Category", $sum_exprs
           FROM "$table"
           GROUP BY "Category" """))

    nrow(agg_df) == 0 && return json_error(400, "no_data", "No data in composition table")

    # Build a matrix: rows = categories (in priority order), cols = samples
    cat_labels = String[]
    counts = Matrix{Float64}(undef, 0, length(scols))
    for cat in cat_names
        idx = findfirst(r -> string(r.Category) == cat, eachrow(agg_df))
        isnothing(idx) && continue
        row_vals = Float64[coalesce(agg_df[idx, c], 0.0) for c in scols]
        any(>(0), row_vals) || continue
        counts = vcat(counts, row_vals')
        push!(cat_labels, cat)
    end

    isempty(cat_labels) && return json_error(400, "no_data", "All categories empty")

    # Pool columns before relativization so proportions reflect true read totals.
    if do_pool
        scols, counts = Analysis.pool_columns(scols, counts, pool_groups;
                                              fallback_label=something(prefix, "Total"))
    end

    # Relativize per sample (column-wise)
    col_sums = vec(sum(counts, dims=1))
    for j in eachindex(scols)
        col_sums[j] > 0 && (counts[:, j] ./= col_sums[j])
    end

    traces = [Dict{String,Any}(
        "type"   => "bar",
        "name"   => cat_labels[i],
        "x"      => scols,
        "y"      => collect(counts[i, :]),
        "marker" => Dict("color" => get(colour_map, cat_labels[i], "#95a5a6")),
    ) for i in eachindex(cat_labels)]

    layout = Dict{String,Any}(
        "barmode" => "stack",
        "title"   => Dict("text" => "Organism composition"),
        "xaxis"   => Dict("title" => "Sample", "tickangle" => -45),
        "yaxis"   => Dict("title" => "Relative abundance", "range" => [0, 1]),
        "legend"  => Dict("traceorder" => "normal"),
    )

    Dict("data" => traces, "layout" => layout)
end

## Routes

# List category sets
@get "/api/v1/category-sets" function(req)
    json(_list_category_sets())
end

# Build composition table
@post "/api/v1/studies/{study}/runs/{run}/composition/{source}/build" function(req,
                                                                                study::String,
                                                                                run::String,
                                                                                source::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    table = string(get(body, :table, "merged"))
    category_set = string(get(body, :category_set, "default"))
    max_x = Int(get(body, :max_x, -1))

    try
        _build_composition!(study, run, source, table, category_set;
                            group=_req_group(req), max_x)
    catch e
        @error "Composition build failed" study run source table category_set exception=(e, catch_backtrace())
        json_error(500, "composition_build_failed",
            "Failed to build composition table: $(sprint(showerror, e))")
    end
end

# Query composition table (paginated)
@post "/api/v1/studies/{study}/runs/{run}/composition/{source}/query" function(req,
                                                                                study::String,
                                                                                run::String,
                                                                                source::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    _with_composition_db(study, run, source; group=_req_group(req)) do con
        _duckdb_paginated_query(con, _COMPOSITION_TABLE, body)
    end
end

# Distinct values for column
@post "/api/v1/studies/{study}/runs/{run}/composition/{source}/distinct/{column}" function(req,
                                                                                            study::String,
                                                                                            run::String,
                                                                                            source::String,
                                                                                            column::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    _with_composition_db(study, run, source; group=_req_group(req)) do con
        _duckdb_distinct(con, _COMPOSITION_TABLE, column, body)
    end
end

# Composition analysis chart
@post "/api/v1/studies/{study}/runs/{run}/composition/{source}/analysis" function(req,
                                                                                    study::String,
                                                                                    run::String,
                                                                                    source::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err
    group = _req_group(req)

    body = JSON3.read(String(req.body))
    category_set = string(get(body, :category_set, "default"))
    prefix = let p = get(body, :prefix, nothing); isnothing(p) ? nothing : string(p) end
    do_pool = Bool(get(body, :pool, false))
    pool_groups_raw = let v = get(body, :pool_groups, nothing)
        isnothing(v) ? String[] : String[string(g) for g in v]
    end

    cat_config = _load_category_set(category_set)
    isnothing(cat_config) && return json_error(404, "category_set_not_found",
        "Category set '$category_set' not found")

    _with_composition_db(study, run, source; group) do con
        fig = _composition_chart(con, _COMPOSITION_TABLE, cat_config;
                                 prefix, do_pool, pool_groups=pool_groups_raw)
        fig isa HTTP.Response && return fig
        HTTP.Response(200, ["Content-Type" => "application/json"],
                      body=JSON3.write(fig))
    end
end
