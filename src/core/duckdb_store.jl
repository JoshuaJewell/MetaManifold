module DuckDBStore

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export load_results_db, with_results_db, with_results_db_write

using DuckDB, Logging, DataFrames, DBInterface

"""
    load_results_db(merge_dir; swarm_dir, tagging)

Create/recreate a DuckDB database at `merge_dir/results.duckdb` by loading all
CSVs in the merge directory. If `swarm_dir` is provided and contains
`cluster_membership.csv`, that table is loaded too.

When `tagging` is a Dict with keys "source", "max_x", "category_sets", and
"library_path", and the merged table is present, this function calls
`Categories.apply_max_x!` then `Categories.write_category_columns!` on it
before closing the connection.
"""
function load_results_db(merge_dir::String;
                         swarm_dir::Union{String,Nothing}=nothing,
                         tagging::Union{Dict,Nothing}=nothing)
    db_path = joinpath(merge_dir, "results.duckdb")
    # Remove stale DB and WAL to avoid schema conflicts on re-runs
    isfile(db_path) && rm(db_path)
    isfile(db_path * ".wal") && rm(db_path * ".wal")

    db  = DuckDB.DB(db_path)
    con = DBInterface.connect(db)
    try
        _esc_id(s) = "\"" * replace(s, "\"" => "\"\"") * "\""
        _esc_str(s) = "'" * replace(s, "'" => "''") * "'"

        for f in readdir(merge_dir)
            endswith(f, ".csv") || continue
            table_name = splitext(f)[1]
            csv_path   = joinpath(merge_dir, f)
            DBInterface.execute(con,
                "CREATE TABLE $(_esc_id(table_name)) AS SELECT * FROM read_csv_auto($(_esc_str(csv_path)), auto_detect=true)")
            @info "DuckDB: loaded $f as table '$table_name'"
        end

        if !isnothing(swarm_dir)
            membership_csv = joinpath(swarm_dir, "cluster_membership.csv")
            if isfile(membership_csv)
                DBInterface.execute(con,
                    "CREATE TABLE cluster_membership AS SELECT * FROM read_csv_auto($(_esc_str(membership_csv)), auto_detect=true)")
                @info "DuckDB: loaded cluster_membership from $membership_csv"
            end
        end

        # Apply tagging (max_x filter + category columns) to the merged table when
        # configured. Access Categories via the parent MetaManifold module so that
        # DuckDBStore does not need to import it at load time (load order: DuckDBStore
        # is included before Categories in MetaManifold.jl).
        if !isnothing(tagging)
            _apply_tagging!(con, tagging)
        end
    finally
        DBInterface.close!(con)
        close(db)
    end

    @info "DuckDB: database written to $db_path"
    return db_path
end

# Check whether a table exists in the open connection.
function _table_exists(con, name::String)
    rows = DataFrame(DBInterface.execute(con,
        "SELECT table_name FROM information_schema.tables WHERE table_name = ?",
        [name]))
    !isempty(rows)
end

# Retrieve the taxonomy rank columns for `source` that are present in `table`.
# Mirrors `_taxonomy_cols_for_source` in composition.jl exactly:
# - VSEARCH: Species, Genus, Family, Order, Class, Division, Supergroup, Subdivision
# - DADA2:   the _dada2 equivalents of the above, plus Domain_dada2
# Domain is excluded from the VSEARCH set (handled only via Domain_dada2 for DADA2).
function _rank_cols_for_source(con, table::String, source::String)
    present = Set(string.(DataFrame(DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_name = ?",
        [table])).column_name))
    # Access rank pairs from the sibling Categories module via the parent module.
    cats_mod = parentmodule(DuckDBStore).Categories
    cols = String[]
    # Iterate RANK_PAIRS but skip Domain/Domain_dada2; VSEARCH has no Domain in
    # the reference set and Domain_dada2 is appended separately below for DADA2.
    for (vs, da) in cats_mod._RANK_PAIRS
        vs == "Domain" && continue
        col = source == "VSEARCH" ? vs : da
        col in present && push!(cols, col)
    end
    # Subdivision is already covered by the loop above; Domain_dada2 is DADA2-only.
    if source == "DADA2"
        "Domain_dada2" in present && push!(cols, "Domain_dada2")
    end
    cols
end

# Internal: apply the tagging block to the merged table in `con`.
function _apply_tagging!(con, tagging::Dict)
    merged_table = "merged"
    _table_exists(con, merged_table) || return nothing

    cats_mod     = parentmodule(DuckDBStore).Categories
    complib_mod  = parentmodule(DuckDBStore).CompositionLibrary
    source       = string(get(tagging, "source", "VSEARCH"))
    max_x        = Int(get(tagging, "max_x", -1))
    set_names    = Vector{String}(get(tagging, "category_sets", String[]))
    library_path = string(get(tagging, "library_path", ""))

    if source != "VSEARCH" && source != "DADA2"
        @warn "Unknown taxonomy source in tagging block; rank columns will be empty" source
    end
    rank_cols = _rank_cols_for_source(con, merged_table, source)
    cats_mod.apply_max_x!(con, merged_table, rank_cols, max_x)

    isempty(set_names) && return nothing
    isempty(library_path) && return nothing
    library = complib_mod.load(library_path)
    cats_mod.write_category_columns!(con, merged_table, source, set_names; library)
    nothing
end

"""
    with_results_db(f, merge_dir)

Open the DuckDB database read-only and pass the connection to `f`.
Ensures the connection and DB are closed after use.
"""
function with_results_db(f::Function, merge_dir::String)
    db_path = joinpath(merge_dir, "results.duckdb")
    isfile(db_path) || error("DuckDB file not found: $db_path")
    db  = DuckDB.DB(db_path; readonly=true)
    con = DBInterface.connect(db)
    try
        return f(con)
    finally
        DBInterface.close!(con)
        close(db)
    end
end

"""
    with_results_db_write(f, merge_dir)

Open the DuckDB database in read-write mode and pass the connection to `f`.
Use this for mutations (CREATE TABLE, DROP TABLE) only; prefer `with_results_db`
for all read operations to avoid unintentional writes.
"""
function with_results_db_write(f::Function, merge_dir::String)
    db_path = joinpath(merge_dir, "results.duckdb")
    isfile(db_path) || error("DuckDB file not found: $db_path")
    db  = DuckDB.DB(db_path)
    con = DBInterface.connect(db)
    try
        return f(con)
    finally
        DBInterface.close!(con)
        close(db)
    end
end

end
