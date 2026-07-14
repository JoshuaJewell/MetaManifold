# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## One-shot composition migration
# Converts the old config/compositions/ + config/filters/ split into a single
# config/composition.yml library, and moves saved table presets to
# config/presets/. Run once; the old directories are backed up, not deleted.
module MigrateComposition

using YAML, OrderedCollections, Dates

# Strip the .yml/.yaml extension to get the library key for a filter file. Every
# caller has already established the name ends in one, so `splitext` (the same
# idiom the filter-preset route uses to name a preset after its file) suffices.
_stem(f::String) = splitext(f)[1]

function convert(config_dir::String)
    comp_dir    = joinpath(config_dir, "compositions")
    filt_dir    = joinpath(config_dir, "filters")
    presets_dir = joinpath(config_dir, "presets")

    sets = OrderedDict{String,Any}()
    referenced = Set{String}()

    ## Read every category set, rewriting each filter reference from a filename
    # to the library name (its stem). This is the step that prevents the
    # dangling-reference bug: the library is keyed by bare stem, so a
    # reference that keeps its .yml suffix would never resolve.
    if isdir(comp_dir)
        for f in sort(readdir(comp_dir))
            (endswith(f, ".yml") || endswith(f, ".yaml")) || continue
            cfg = YAML.load_file(joinpath(comp_dir, f))
            cats = OrderedDict{String,Any}[]
            for cat in get(cfg, "categories", [])
                entry = OrderedDict{String,Any}("name" => string(get(cat, "name", "")))
                haskey(cat, "colour") && (entry["colour"] = cat["colour"])
                if haskey(cat, "filter")
                    key = _stem(string(cat["filter"]))
                    entry["filter"] = key
                    push!(referenced, key)
                end
                haskey(cat, "funcdb_require") && (entry["funcdb_require"] = cat["funcdb_require"])
                push!(cats, entry)
            end
            set_entry = OrderedDict{String,Any}("categories" => cats)
            haskey(cfg, "name") && (set_entry["label"] = cfg["name"])
            haskey(cfg, "description") && (set_entry["description"] = cfg["description"])
            haskey(cfg, "unassigned_colour") && (set_entry["unassigned_colour"] = cfg["unassigned_colour"])
            sets[_stem(f)] = set_entry
        end
    end

    ## Split the old filters into membership filters and saved table presets.
    # Membership is NOT decided by reference alone: config/filters/ is a library
    # of taxonomic definitions, several of which no shipped set happens to cite
    # (bacteria_archaea, environmental_protozoa, parasitic_protozoa,
    # plants_invertebrates). Demoting those to table presets would strip them
    # from the composition builder and lose curated work. A membership filter
    # declares the taxonomy database it is written against (`databases:`); a
    # saved table preset, written by the Tables view, never does.
    filters = OrderedDict{String,Any}()
    moved = String[]
    if isdir(filt_dir)
        for f in sort(readdir(filt_dir))
            (endswith(f, ".yml") || endswith(f, ".yaml")) || continue
            key = _stem(f)
            cfg = YAML.load_file(joinpath(filt_dir, f))
            is_membership = key in referenced ||
                            (cfg isa AbstractDict && haskey(cfg, "databases"))
            if is_membership
                filters[key] = cfg
            else
                mkpath(presets_dir)
                cp(joinpath(filt_dir, f), joinpath(presets_dir, f); force=true)
                push!(moved, f)
            end
        end
    end

    ## Back up the old tree before removing it, so nothing curated is lost.
    stamp = Dates.format(now(), "yyyymmdd-HHMMSS")
    backup_dir = joinpath(config_dir, "backup-$stamp")
    mkpath(backup_dir)
    isdir(comp_dir) && cp(comp_dir, joinpath(backup_dir, "compositions"))
    isdir(filt_dir) && cp(filt_dir, joinpath(backup_dir, "filters"))

    library_path = joinpath(config_dir, "composition.yml")
    open(library_path, "w") do io
        YAML.write(io, OrderedDict{String,Any}("filters" => filters, "sets" => sets))
    end

    isdir(comp_dir) && rm(comp_dir; recursive=true)
    isdir(filt_dir) && rm(filt_dir; recursive=true)

    (; library_path, presets_moved = moved, backup_dir)
end

end # module
