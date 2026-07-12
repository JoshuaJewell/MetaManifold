# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Category-set loading and SQL-fragment generation for composition analysis.
# Self-contained: does not depend on the quarantined FuncDB annotation module
# or on any server-state globals. All directory paths are passed explicitly.
module Categories

using YAML, DuckDB, DBInterface, DataFrames

## Rank-name translation between the VSEARCH-named merged columns and their
## DADA2 counterparts. Self-contained so categorisation does not depend on the
## quarantined FuncDB annotation module.
const _RANK_PAIRS = [
    ("Domain",     "Domain_dada2"),
    ("Supergroup", "Supergroup_dada2"),
    ("Division",   "Division_dada2"),
    ("Subdivision","Subdivision_dada2"),
    ("Class",      "Class_dada2"),
    ("Order",      "Order_dada2"),
    ("Family",     "Family_dada2"),
    ("Genus",      "Genus_dada2"),
    ("Species",    "Species_dada2"),
]

# Return the column name used in the composed table for a category set.
column_name(set_name::AbstractString) = "Category__" * String(set_name)

## Category-set YAML loading

# Load a named category set from `compositions_dir`. Returns `nothing` when the
# set does not exist or the name is unsafe (path-traversal guard).
function load_category_set(name::String; compositions_dir::String)
    occursin(r"^[a-zA-Z0-9._-]+$", name) || return nothing
    isdir(compositions_dir) || return nothing
    path = joinpath(compositions_dir, name * ".yml")
    isfile(path) || return nothing
    YAML.load_file(path)
end

# List all category sets found in `compositions_dir`, sorted by filename.
function list_category_sets(compositions_dir::String)
    isdir(compositions_dir) || return []
    sets = Dict{String,Any}[]
    for f in sort(readdir(compositions_dir))
        (endswith(f, ".yml") || endswith(f, ".yaml")) || continue
        config = try YAML.load_file(joinpath(compositions_dir, f)) catch; continue end
        name = f[1:end - (endswith(f, ".yaml") ? 5 : 4)]
        push!(sets, config)  # callers may enrich with the name separately
        # Replace the bare config with a minimal keyed entry matching
        # the shape the server route needs: delegate to caller for richer
        # summaries, but at minimum expose "name" for pipeline callers.
        sets[end] = merge(config, Dict("_set_name" => name))
    end
    sets
end

## Filter to SQL translation

# Escape a value for embedding in a single-quoted SQL string literal: any
# embedded single-quote is doubled so the literal closes correctly.
_sql_str(s) = "'" * replace(string(s), "'" => "''") * "'"

# Build a mapping from VSEARCH column names (used in filter YAMLs) to the
# actual column names for the selected source. For VSEARCH this is identity;
# for DADA2 taxonomy columns become their _dada2 equivalents.
# Subdivision is not in RANK_HIERARCHY but exists in merged tables and is
# handled explicitly here.
function col_translate_map(source::String)
    m = Dict{String,String}()
    for (vs, da) in _RANK_PAIRS
        m[vs] = source == "VSEARCH" ? vs : da
    end
    m
end

"""
    filter_to_sql_conditions(filter_config, col_set, table_alias; col_map) -> Vector{String}

Translate a filter YAML config (from config/filters/) into SQL condition
fragments. All conditions within a single filter are AND'd together.
`col_set` is a Set of available columns (for validation).
`table_alias` is the SQL alias prefix (e.g. "m" for the merged table).
Pass `""` to emit bare column references (for UPDATE SET contexts).
`col_map` translates filter column names to actual table column names
(for source-awareness).
"""
function filter_to_sql_conditions(filter_config::Dict, col_set::Set{String},
                                  table_alias::String;
                                  col_map::Dict{String,String}=Dict{String,String}())
    _xlate(c) = get(col_map, c, c)
    # Prefix a column name with the alias, or emit a bare quoted name when no alias.
    _ref(c) = isempty(table_alias) ? "\"$c\"" : "$table_alias.\"$c\""

    conditions = String[]
    raw_filters = get(filter_config, "filters", [])

    # remove_empty conditions
    for col in get(filter_config, "remove_empty", [])
        col_str = _xlate(string(col))
        col_str in col_set || continue
        r = _ref(col_str)
        push!(conditions,
            """($r IS NOT NULL AND TRIM(CAST($r AS VARCHAR)) != '' AND LOWER(TRIM(CAST($r AS VARCHAR))) != 'blank')""")
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
            r = _ref(col)

            if use_regex
                match_expr = "REGEXP_MATCHES(CAST($r AS VARCHAR), $(_sql_str(pat)))"
            else
                # Escape the pattern before embedding in a LIKE literal so a
                # single-quote in `pat` cannot break out of the string.
                pat_esc = replace(pat, "'" => "''")
                match_expr = "CAST($r AS VARCHAR) LIKE '%$(pat_esc)%'"
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
            r = _ref(col)
            if typ == "min"
                val = get(item, "value", nothing)
                isnothing(val) && continue
                # Validate numerically: an unvalidated string could inject SQL.
                parsed = tryparse(Float64, string(val))
                isnothing(parsed) && continue
                push!(conditions, "TRY_CAST($r AS DOUBLE) >= $parsed")
            elseif typ == "max"
                val = get(item, "value", nothing)
                isnothing(val) && continue
                parsed = tryparse(Float64, string(val))
                isnothing(parsed) && continue
                push!(conditions, "TRY_CAST($r AS DOUBLE) <= $parsed")
            elseif typ == "include"
                vals = get(item, "values", [])
                isempty(vals) && continue
                # Escape each value so single-quotes cannot break the IN literal.
                val_list = join([_sql_str(v) for v in vals], ", ")
                push!(conditions, "CAST($r AS VARCHAR) IN ($val_list)")
            end
        end
    end

    conditions
end

# Column names a filter config references, translated for the selected source
# via `col_map`. Covers `remove_empty` entries and any `filters` item carrying a
# `column`. Used to check a filter is fully realisable against a table's schema.
function filter_column_refs(filter_config::Dict;
                            col_map::Dict{String,String}=Dict{String,String}())
    _xlate(c) = get(col_map, c, c)
    refs = String[]
    for col in get(filter_config, "remove_empty", [])
        push!(refs, _xlate(string(col)))
    end
    for item in get(filter_config, "filters", [])
        item isa Dict || continue
        (haskey(item, "pattern") || haskey(item, "type")) || continue
        col = string(get(item, "column", ""))
        isempty(col) && continue
        push!(refs, _xlate(col))
    end
    refs
end

"""
    category_case_when(categories, merged_col_set, source; filters_dir, table_alias, strict) -> Union{String,Nothing}

Build a SQL CASE WHEN expression that classifies each row into a category.
Filter column names are translated to the correct source columns (VSEARCH or
DADA2). The `funcdb_require` key on a category entry is silently ignored
(FuncDB is quarantined).
`table_alias` defaults to "m" (SELECT context with FROM ... m); pass "" for
UPDATE SET contexts where bare column references are required.

A category carrying no `filter` names the catch-all bucket: its name becomes the
CASE `ELSE` label (the last such category wins), so every row unmatched by the
filtered categories is labelled with it rather than the default `Unassigned`.
This lets a set model "everything else", contaminants included, as an explicit
named, colourable category.

By default (`strict=false`, for display) a filter that references an absent
column has that condition dropped and still contributes a branch, and the
result is always a string. With `strict=true` (for row-dropping figure
exclusion) the classification must be exactly realisable: if any category's
filter is unsafe, missing, unparseable, or references a column absent from
`merged_col_set`, or no category yields a branch, `nothing` is returned so the
caller drops nothing rather than the wrong rows.
"""
function category_case_when(categories::Vector, merged_col_set::Set{String},
                            source::String; filters_dir::String,
                            table_alias::String="m", strict::Bool=false)
    col_map = col_translate_map(source)
    branches = String[]
    catchall = "Unassigned"

    for cat in categories
        cat_name = get(cat, "name", "")
        isempty(cat_name) && continue

        filter_file = get(cat, "filter", nothing)
        # A filterless category names the catch-all bucket (the ELSE label).
        isnothing(filter_file) && (catchall = string(cat_name); continue)

        # The filter name becomes a path component; reject anything outside safe
        # identifier characters so it cannot traverse to an arbitrary file.
        if !occursin(r"^[a-zA-Z0-9._-]+$", string(filter_file))
            strict && return nothing
            continue
        end
        filter_path = joinpath(filters_dir, string(filter_file))
        if !isfile(filter_path)
            strict && return nothing
            continue
        end
        filter_config = try
            YAML.load_file(filter_path)
        catch
            strict && return nothing
            continue
        end

        # A strict caller drops rows on this classification, so a partially
        # degraded filter (any referenced column absent) is untrustworthy: bail
        # rather than silently over- or under-match. Display callers tolerate it.
        if strict && any(ref -> !(ref in merged_col_set),
                         filter_column_refs(filter_config; col_map))
            return nothing
        end

        conditions = filter_to_sql_conditions(filter_config, merged_col_set,
                                              table_alias; col_map)

        # funcdb_require is ignored: FuncDB is quarantined and its annotation
        # columns are not available in the pipeline-side composition path.
        isempty(conditions) && continue
        # Escape single-quotes in the category name so a crafted name cannot
        # break out of the THEN string literal.
        push!(branches, "WHEN (" * join(conditions, " AND ") * ") THEN $(_sql_str(cat_name))")
    end

    isempty(branches) && return strict ? nothing : _sql_str(catchall)
    "CASE\n    " * join(branches, "\n    ") * "\n    ELSE $(_sql_str(catchall))\nEND"
end

## DuckDB category-column writer and lazy backfill

"""
    write_category_columns!(con, table, source, set_names; compositions_dir, filters_dir)

For each category set in `set_names`, add a `Category__<set>` VARCHAR column to
`table` (idempotent via ADD COLUMN IF NOT EXISTS) and UPDATE it with the
CASE WHEN classification expression for `source`. Columns already populated are
still refreshed by the UPDATE; use `ensure_columns!` for a pure backfill.
"""
function write_category_columns!(con, table::String, source::String,
                                 set_names::Vector{String};
                                 compositions_dir::String, filters_dir::String)
    cols = Set(string.(DataFrame(DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_name = ?",
        [table])).column_name))
    for set_name in set_names
        # Guard: the set name is used as a quoted SQL identifier. Reject any
        # name that falls outside safe identifier characters so a double-quote
        # cannot escape the quoting and inject SQL.
        if !occursin(r"^[A-Za-z0-9._-]+$", set_name)
            @warn "write_category_columns!: skipping set with unsafe name" set_name
            continue
        end
        cfg = load_category_set(set_name; compositions_dir)
        isnothing(cfg) && continue
        cats = get(cfg, "categories", [])
        # Use empty alias: UPDATE runs against the bare table, no FROM alias.
        case = category_case_when(cats, cols, source;
                                  filters_dir, table_alias="")
        colname = column_name(set_name)
        DBInterface.execute(con,
            "ALTER TABLE \"$table\" ADD COLUMN IF NOT EXISTS \"$colname\" VARCHAR")
        DBInterface.execute(con,
            "UPDATE \"$table\" SET \"$colname\" = $case")
    end
    nothing
end

"""
    apply_max_x!(con, table, rank_cols, max_x)

Delete rows from `table` whose count of unresolved `_X` placeholders across
`rank_cols` exceeds `max_x`. Does nothing when `max_x < 0`.

The count expression mirrors `_build_quality_where` in
`src/server/routes/composition.jl`: NULL/empty/NA columns each contribute 1;
non-empty columns contribute the number of `_X` substrings measured by the
LENGTH/REPLACE trick `(LENGTH(col) - LENGTH(REPLACE(col, '_X', ''))) / 2`.
"""
function apply_max_x!(con, table::String, rank_cols::Vector{String}, max_x::Int)
    max_x < 0 && return nothing
    isempty(rank_cols) && return nothing
    x_checks = String[]
    for c in rank_cols
        push!(x_checks, """CASE
            WHEN \"$c\" IS NULL OR TRIM(CAST(\"$c\" AS VARCHAR)) = '' OR LOWER(TRIM(CAST(\"$c\" AS VARCHAR))) = 'na'
                THEN 1
            ELSE (LENGTH(CAST(\"$c\" AS VARCHAR)) - LENGTH(REPLACE(CAST(\"$c\" AS VARCHAR), '_X', ''))) / 2
        END""")
    end
    count_expr = join(x_checks, " + ")
    DBInterface.execute(con,
        "DELETE FROM \"$table\" WHERE ($count_expr) > $max_x")
    nothing
end

"""
    ensure_columns!(con, table, source, set_names; compositions_dir, filters_dir)

Lazy backfill: write only the `Category__<set>` columns that are absent from
`table`, leaving any already-present ones untouched. Idempotent.
"""
function ensure_columns!(con, table::String, source::String,
                         set_names::Vector{String};
                         compositions_dir::String, filters_dir::String)
    present = Set(string.(DataFrame(DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_name = ?",
        [table])).column_name))
    missing_sets = filter(s -> !(column_name(s) in present), set_names)
    isempty(missing_sets) && return nothing
    write_category_columns!(con, table, source, missing_sets;
                            compositions_dir, filters_dir)
    nothing
end

end # module Categories
