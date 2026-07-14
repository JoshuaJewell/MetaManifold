# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: organism composition - category-based classification of ASVs/OTUs
# for relative abundance analysis across broad organism groups.
using JSON3, CSV, DataFrames, OrderedCollections, DuckDB, DBInterface, YAML
using MetaManifold.Categories, MetaManifold.CompositionLibrary

# Catch-all bucket for taxa matching no category, and its fixed legend colour.
const _UNASSIGNED_CATEGORY = "Unassigned"
const _UNASSIGNED_COLOUR = "#95a5a6"

## Composition library
function _library_path()
    joinpath(dirname(ServerState.projects_dir()), "config", "composition.yml")
end

_library() = CompositionLibrary.load(_library_path())

# Write the whole library back to config/composition.yml.
function _write_library(lib::Dict)
    path = _library_path()
    mkpath(dirname(path))
    open(path, "w") do io
        YAML.write(io, lib)
    end
end

# List the category sets defined in the composition library.
function _list_category_sets()
    sets = Dict{String,Any}[]
    for (name, config) in sort(collect(_library()["sets"]); by=first)
        push!(sets, _category_set_summary(name, config))
    end
    sets
end

# Persist the whole library, validating the document before it lands on disk.
# This is the single gate through which every filter and set write passes, so
# a dangling filter reference is caught here rather than reaching the SQL
# generator, where it would silently classify every row as 'Unassigned'.
# Returns the library, or an HTTP.Response error.
function _save_library(lib::Dict)
    errors = CompositionLibrary.validate(lib)
    isempty(errors) || return json_error(400, "invalid_library", join(errors, "; "))
    _write_library(lib)
    lib
end

# Save a filter config verbatim into the library. Returns the saved filter
# config, or an HTTP.Response error.
function _save_filter(name::String, config::AbstractDict)
    lib = _library()
    lib["filters"][name] = config
    result = _save_library(lib)
    result isa HTTP.Response && return result
    @info "Saved filter: $name (library $(_library_path()))"
    result["filters"][name]
end

# Remove a filter from the library; refuses when a set still references it,
# naming the referencing sets. Returns the deleted name, or an HTTP.Response.
function _delete_filter(name::String)
    lib = _library()
    users = CompositionLibrary.filter_in_use(lib, name)
    isempty(users) || return json_error(409, "filter_in_use",
        "Filter '$name' is used by: " * join(users, ", "))
    haskey(lib["filters"], name) || return json_error(404, "filter_not_found",
        "Filter '$name' not found")
    delete!(lib["filters"], name)
    _write_library(lib)
    @info "Deleted filter: $name (library $(_library_path()))"
    name
end

# Save a whole set config verbatim into the library. This is the composition
# builder's direct-save path, distinct from `_save_category_set`'s
# save-as-a-recolour path used by the existing category-sets routes. Returns
# the saved set config, or an HTTP.Response error.
function _save_composition_set(name::String, config::AbstractDict)
    lib = _library()
    lib["sets"][name] = config
    result = _save_library(lib)
    result isa HTTP.Response && return result
    @info "Saved category set: $name (library $(_library_path()))"
    result["sets"][name]
end

## Filter to SQL translation
# These helpers now delegate to the Categories module, which is self-contained
# and does not depend on FuncDBAnnotation or server-state globals.
_col_translate_map(source::String) = Categories.col_translate_map(source)

_filter_to_sql_conditions(filter_config::Dict, col_set::Set{String},
                          table_alias::String;
                          col_map::Dict{String,String}=Dict{String,String}()) =
    Categories.filter_to_sql_conditions(filter_config, col_set, table_alias; col_map)

## Live composition summary

"""
    _composition_summary(study, run, category_set_name, subgroup; group) -> HTTP.Response

Compute a live composition summary directly from the merged results table.
Ensures the `Category__<set>` column exists (lazily writing it when absent),
then groups by that column to produce per-category row and read counts.

`subgroup` is either `nothing` (all sample columns) or a prefix string
(columns matching `"<prefix>_"`). Returns a 400 when the subgroup prefix
matches no sample columns.

The returned JSON matches the `CompositionBuildResult` frontend type:
`{ table, source, category_set, total_rows, total_reads, categories }`.
"""
function _composition_summary(study::String, run::String, category_set_name::String,
                               subgroup::Union{String,Nothing};
                               group::Union{String,Nothing}=nothing)
    merge_dir = _require_duckdb(study, run; group)
    isnothing(merge_dir) && return json_error(404, "no_results",
        "No results database for run '$run' - run the pipeline first")

    # The name is interpolated into a quoted SQL identifier below, via
    # `Categories.column_name`. Membership of the library is not by itself a
    # character guarantee: it holds only because every API write charset-checks the
    # key. Re-assert the guard here so the safety of this SQL does not depend on an
    # invariant enforced in another module.
    Validation.is_safe_name(category_set_name) ||
        return json_error(400, "invalid_name",
            "Category set name must contain only letters, numbers, dots, hyphens, and underscores")

    lib = _library()
    haskey(lib["sets"], category_set_name) || return json_error(404, "category_set_not_found",
        "Category set '$category_set_name' not found")

    source = _tagging_source(study, run; group)
    col = Categories.column_name(category_set_name)

    with_results_db_write(merge_dir) do con
        # Ensure the category column is present; backfill when absent.
        Categories.ensure_columns!(con, "merged", source, [category_set_name];
                                   library=lib)

        all_sample_cols = Analysis.sample_columns(con, "merged")

        # Resolve the retained sample columns for the requested subgroup.
        retained = _filter_by_prefix(all_sample_cols, subgroup)
        isempty(retained) && return json_error(400, "no_subgroup_samples",
            "Sub-group selection '$(something(subgroup, ""))' matches no sample columns in 'merged'")

        # Per-row read sum (for the WHERE clause) and per-group read sum (for SELECT).
        row_sum  = join(["COALESCE(\"$c\", 0)" for c in retained], " + ")
        grp_sum  = join(["COALESCE(SUM(\"$c\"), 0)" for c in retained], " + ")

        # Exclude rows whose read sum across the retained columns is zero, then
        # group by category. The HAVING clause drops any category whose aggregate
        # is also zero (defensive; the WHERE should already prevent this).
        sql = """
            SELECT \"$col\" AS cat, COUNT(*) AS rows, ($grp_sum) AS reads
            FROM merged
            WHERE ($row_sum) > 0
            GROUP BY \"$col\"
            HAVING ($grp_sum) > 0
        """
        df = DataFrame(DBInterface.execute(con, sql))

        total_rows  = sum(df.rows;  init=0)
        total_reads = sum(df.reads; init=0)

        cat_stats = OrderedDict{String,Any}()
        for row in eachrow(df)
            cat_stats[string(row.cat)] = Dict(
                "rows"          => Int(row.rows),
                "reads"         => Int(row.reads),
                "reads_percent" => total_reads > 0 ?
                    round(100.0 * row.reads / total_reads; digits=2) : 0.0,
            )
        end

        json(Dict(
            "table"        => "merged",
            "source"       => source,
            "category_set" => category_set_name,
            "total_rows"   => total_rows,
            "total_reads"  => total_reads,
            "categories"   => cat_stats,
        ))
    end
end

## Routes

# The whole composition library: filters plus sets, for the frontend's
# composition builder (Tasks 7-8).
@get "/api/v1/composition" function(req)
    json(_library())
end

# Create or update a named filter. The whole library is validated before the
# write lands on disk, so a name violating the charset or a value that is not
# a Dict is rejected with 400 "invalid_library".
@post "/api/v1/composition/filters/{name}" function(req, name::String)
    body = _to_plain(JSON3.read(String(req.body)))
    result = _save_filter(name, body)
    result isa HTTP.Response && return result
    json(result)
end

# Delete a filter. Refused with 409 "filter_in_use" (naming the referencing
# sets) while any set still references it; 404 "filter_not_found" when absent.
@delete "/api/v1/composition/filters/{name}" function(req, name::String)
    result = _delete_filter(name)
    result isa HTTP.Response && return result
    json((; deleted=result))
end

# Create or update a set from its whole config (label, description,
# unassigned_colour, categories). A category naming a filter absent from the
# library fails validation and is rejected with 400 "invalid_library".
@post "/api/v1/composition/sets/{name}" function(req, name::String)
    body = _to_plain(JSON3.read(String(req.body)))
    result = _save_composition_set(name, body)
    result isa HTTP.Response && return result
    json(result)
end

# Delete a set; `default` is protected. Shares `_delete_category_set` since
# the library is the single store regardless of which route deletes a set.
@delete "/api/v1/composition/sets/{name}" function(req, name::String)
    result = _delete_category_set(name)
    result isa HTTP.Response && return result
    json((; deleted=result))
end

# List category sets
@get "/api/v1/category-sets" function(req)
    json(_list_category_sets())
end

# Emit one saved category set in the shape `_list_category_sets` produces.
function _category_set_summary(name::String, config)
    cs = get(config, "categories", [])
    cats = [Dict("name" => get(c, "name", ""), "colour" => get(c, "colour", nothing))
            for c in cs]
    Dict(
        "name"             => name,
        "label"            => get(config, "label", get(config, "name", name)),
        "description"      => get(config, "description", ""),
        "categories"       => cats,
        "unassigned_colour" => string(get(config, "unassigned_colour", _UNASSIGNED_COLOUR)),
    )
end

# Clone the base set's structure verbatim, overriding only the colours by
# category name, and write the updated set into the library at
# `config/composition.yml`. Returns the saved set summary, or an
# `HTTP.Response` error mirroring the route's failure modes.
function _save_category_set(name::String, base::String,
                            colours::Dict{String,String};
                            label::Union{String,Nothing}=nothing,
                            description::Union{String,Nothing}=nothing)
    Validation.is_safe_name(name) || return json_error(400, "invalid_name",
        "Name must contain only letters, numbers, dots, hyphens, and underscores")
    isempty(base) && return json_error(400, "missing_base", "Body must include 'base'")

    lib = _library()
    base_config = get(lib["sets"], base, nothing)
    isnothing(base_config) && return json_error(404, "base_not_found",
        "Base category set '$base' not found")

    for clr in values(colours)
        occursin(CompositionLibrary.COLOUR_RE, clr) || return json_error(400, "invalid_colour",
            "Colour '$clr' must be a hex triplet like '#3498db'")
    end

    # Rebuild the category list preserving order, `filter`, and `funcdb_require`
    # byte-for-byte; only `colour` is replaced where an override is supplied.
    base_cats = get(base_config, "categories", [])
    out_cats = OrderedDict{String,Any}[]
    for cat in base_cats
        cat_name = string(get(cat, "name", ""))
        entry = OrderedDict{String,Any}("name" => cat_name)
        new_colour = get(colours, cat_name, get(cat, "colour", nothing))
        isnothing(new_colour) || (entry["colour"] = string(new_colour))
        haskey(cat, "filter") && (entry["filter"] = cat["filter"])
        haskey(cat, "funcdb_require") && (entry["funcdb_require"] = cat["funcdb_require"])
        push!(out_cats, entry)
    end

    out = OrderedDict{String,Any}(
        "label"       => isnothing(label) ? get(base_config, "label", name) : label,
        "description" => isnothing(description) ? get(base_config, "description", "") : description,
        "categories"  => out_cats,
    )

    # Route the "Unassigned" colour override to the top-level field rather than a category entry.
    unassigned = get(colours, _UNASSIGNED_CATEGORY,
                     get(base_config, "unassigned_colour", nothing))
    isnothing(unassigned) || (out["unassigned_colour"] = string(unassigned))

    lib["sets"][name] = out
    result = _save_library(lib)
    result isa HTTP.Response && return result
    @info "Saved category set: $name (library $(_library_path()))"
    _category_set_summary(name, out)
end

# Remove a set from the library; `default` is protected. Returns the deleted
# name, or an `HTTP.Response` error.
function _delete_category_set(name::String)
    Validation.is_safe_name(name) || return json_error(400, "invalid_name",
        "Name must contain only letters, numbers, dots, hyphens, and underscores")
    name == "default" && return json_error(400, "protected_set",
        "The 'default' category set cannot be deleted")

    lib = _library()
    haskey(lib["sets"], name) || return json_error(404, "set_not_found",
        "Category set '$name' not found")
    delete!(lib["sets"], name)
    _write_library(lib)
    @info "Deleted category set: $name (library $(_library_path()))"
    name
end

# Save a category set, mirroring the filter-preset save apparatus.
@post "/api/v1/category-sets/{name}" function(req, name::String)
    body = JSON3.read(String(req.body))
    base = string(get(body, :base, ""))
    colours = Dict{String,String}()
    let c = get(body, :colours, nothing)
        isnothing(c) || for (cat, clr) in pairs(c)
            colours[string(cat)] = string(clr)
        end
    end
    label = let l = get(body, :label, nothing); isnothing(l) ? nothing : string(l) end
    description = let d = get(body, :description, nothing); isnothing(d) ? nothing : string(d) end

    result = _save_category_set(name, base, colours; label, description)
    result isa HTTP.Response && return result
    json(result)
end

# Delete a category set; `default` is protected and cannot be removed.
@delete "/api/v1/category-sets/{name}" function(req, name::String)
    result = _delete_category_set(name)
    result isa HTTP.Response && return result
    json((; deleted=result))
end

# Live composition summary: compute per-category row and read counts from the
# merged table, ensuring the Category__ column exists first.
@post "/api/v1/studies/{study}/runs/{run}/composition/summary" function(req,
                                                                         study::String,
                                                                         run::String)
    study in _study_names() || return json_error(404, "study_not_found",
        "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
        "Run '$run' not found")

    body = JSON3.read(String(req.body))
    category_set = string(get(body, :category_set, "default"))
    subgroup = let s = get(body, :subgroup, nothing)
        isnothing(s) ? nothing : string(s)
    end

    try
        _composition_summary(study, run, category_set, subgroup;
                             group=_req_group(req))
    catch e
        @error "Composition summary failed" study run category_set subgroup exception=(e, catch_backtrace())
        json_error(500, "composition_summary_failed",
            "Failed to compute composition summary: $(sprint(showerror, e))")
    end
end

# Query merged table (paginated), ensuring the requested category set column exists.
@post "/api/v1/studies/{study}/runs/{run}/composition/{source}/query" function(req,
                                                                                study::String,
                                                                                run::String,
                                                                                source::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err
    group = _req_group(req)

    body = JSON3.read(String(req.body))
    category_set = string(get(body, :category_set, "default"))

    merge_dir = _require_duckdb(study, run; group)
    isnothing(merge_dir) && return json_error(404, "no_results",
        "No results database for run '$run' - run the pipeline first")

    tag_src = _tagging_source(study, run; group)
    with_results_db_write(merge_dir) do con
        Categories.ensure_columns!(con, "merged", tag_src, [category_set];
                                   library=_library())
        _duckdb_paginated_query(con, "merged", body)
    end
end

# Distinct values for a merged-table column; ensures category column when requested.
@post "/api/v1/studies/{study}/runs/{run}/composition/{source}/distinct/{column}" function(req,
                                                                                            study::String,
                                                                                            run::String,
                                                                                            source::String,
                                                                                            column::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err
    group = _req_group(req)

    body = JSON3.read(String(req.body))
    category_set = string(get(body, :category_set, "default"))

    merge_dir = _require_duckdb(study, run; group)
    isnothing(merge_dir) && return json_error(404, "no_results",
        "No results database for run '$run' - run the pipeline first")

    tag_src = _tagging_source(study, run; group)
    with_results_db_write(merge_dir) do con
        Categories.ensure_columns!(con, "merged", tag_src, [category_set];
                                   library=_library())
        _duckdb_distinct(con, "merged", column, body)
    end
end


