# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## Composition library
# Loads and writes config/composition.yml: a named filter library plus the
# category sets that reference those filters by name.
module CompositionLibrary

using YAML
using ..Validation

# An empty library, used when the file is absent.
_empty() = Dict{String,Any}("filters" => Dict{String,Any}(),
                            "sets"    => Dict{String,Any}())

# Coerce a filters map's keys to String so downstream lookups never depend on
# the type YAML inferred for the key (an unquoted numeric name parses as an
# Int64, not a String). Accepts any Dict-like value (plain Dict from YAML, or
# OrderedDict from a caller that built the library in memory).
_normalise_filters(filters) = filters isa AbstractDict ?
    Dict{String,Any}(string(k) => v for (k, v) in filters) : filters

# Coerce a sets map's keys, and each category's filter reference, to String.
function _normalise_sets(sets)
    sets isa AbstractDict || return sets
    Dict{String,Any}(string(set_name) => _normalise_set_cfg(set_cfg)
                      for (set_name, set_cfg) in sets)
end

function _normalise_set_cfg(set_cfg)
    set_cfg isa AbstractDict || return set_cfg
    cfg = Dict{String,Any}(set_cfg)
    cats = get(cfg, "categories", nothing)
    cats isa Vector && (cfg["categories"] = [_normalise_category(c) for c in cats])
    cfg
end

# A filter-less category is the legitimate catch-all; leave it without a
# "filter" key rather than manufacturing the string "nothing".
function _normalise_category(cat)
    cat isa AbstractDict || return cat
    c = Dict{String,Any}(cat)
    haskey(c, "filter") && (c["filter"] = string(c["filter"]))
    c
end

# Load the library document. A missing file yields an empty library so a fresh
# install behaves as though no sets are defined rather than erroring.
function load(path::String)
    isfile(path) || return _empty()
    raw = YAML.load_file(path)
    raw isa AbstractDict || return _empty()
    Dict{String,Any}(
        "filters" => _normalise_filters(get(raw, "filters", Dict{String,Any}())),
        "sets"    => _normalise_sets(get(raw, "sets", Dict{String,Any}())),
    )
end

## Validation
const _NAME_RE  = Validation.SAFE_NAME_RE
# Public so a route checking a colour before it reaches `validate` tests it
# against the same pattern the document is held to, rather than a hand-copied
# twin that can drift out of step with it.
const COLOUR_RE = r"^#[0-9a-fA-F]{6}$"

# Names of the sets that reference `name` as a category filter. Values are
# stringified before comparison since a numeric filter name survives YAML as
# an Int64 while `name` is always a String.
function filter_in_use(lib::Dict, name::String)
    users = String[]
    for (set_name, set_cfg) in get(lib, "sets", Dict())
        set_cfg isa AbstractDict || continue
        for cat in get(set_cfg, "categories", [])
            cat isa AbstractDict || continue
            fref = get(cat, "filter", nothing)
            isnothing(fref) && continue
            string(fref) == name && (push!(users, string(set_name)); break)
        end
    end
    sort(users)
end

# Check the whole library. Returns human-readable errors; empty means valid.
# Never throws: every section and entry is type-checked before use, so a
# malformed edit is rejected with a message rather than crashing the caller.
function validate(lib::Dict)
    errors = String[]
    filters = get(lib, "filters", Dict())
    if filters isa AbstractDict
        for (fname, fval) in filters
            occursin(_NAME_RE, string(fname)) ||
                push!(errors, "Filter name '$fname' may contain only letters, numbers, dots, hyphens, and underscores")
            fval isa AbstractDict ||
                push!(errors, "Filter '$fname' value must be a Dict, not $(typeof(fval))")
        end
    else
        push!(errors, "Filters section must be a Dict, not $(typeof(filters))")
        filters = Dict()
    end
    # Compare references against stringified keys, so a library built by a caller
    # rather than by `load` (where a numeric name parses as an integer) does not
    # raise a false dangling error for a filter that is present.
    filter_names = Set{String}(string(k) for k in keys(filters))

    sets = get(lib, "sets", Dict())
    if !(sets isa AbstractDict)
        push!(errors, "Sets section must be a Dict, not $(typeof(sets))")
        return errors
    end

    for (set_name, set_cfg) in sets
        occursin(_NAME_RE, string(set_name)) ||
            push!(errors, "Set name '$set_name' may contain only letters, numbers, dots, hyphens, and underscores")
        if !(set_cfg isa AbstractDict)
            push!(errors, "Set '$set_name' value must be a Dict, not $(typeof(set_cfg))")
            continue
        end
        categories = get(set_cfg, "categories", [])
        if !(categories isa Vector)
            push!(errors, "Categories in set '$set_name' must be a list, not $(typeof(categories))")
            continue
        end
        for cat in categories
            if !(cat isa AbstractDict)
                push!(errors, "A category in set '$set_name' must be a Dict, not $(typeof(cat))")
                continue
            end
            cat_name = string(get(cat, "name", ""))
            colour = get(cat, "colour", nothing)
            isnothing(colour) || occursin(COLOUR_RE, string(colour)) ||
                push!(errors, "Colour '$colour' on category '$cat_name' must be a hex triplet like '#3498db'")
            fref = get(cat, "filter", nothing)
            isnothing(fref) && continue
            string(fref) in filter_names ||
                push!(errors, "Category '$cat_name' in set '$set_name' names filter '$fref', which is not in the library")
        end
    end
    errors
end

end # module
