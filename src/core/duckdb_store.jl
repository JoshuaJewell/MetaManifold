module DuckDBStore

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export load_results_db, with_results_db, with_results_db_write

using DuckDB, Logging, DataFrames, DBInterface

## Per-database serialisation
# DuckDB allows either one writer or several readers on a file, and enforces that with
# a lock of its own that throws when a second writer arrives. Concurrent HTTP handlers,
# or a pipeline job writing while a request reads, would collide on it, so every open
# of a results database goes through a readers/writer lock keyed by the resolved path.
mutable struct _DBLock
    guard   :: ReentrantLock
    ready   :: Threads.Condition
    readers :: Int                 # read slots currently held, across all tasks
    depths  :: Dict{Task,Int}      # read depth per task, so a nested read is re-entrant
    writer  :: Union{Task,Nothing}
    wdepth  :: Int                 # write depth of `writer`, likewise re-entrant
    function _DBLock()
        guard = ReentrantLock()
        new(guard, Threads.Condition(guard), 0, Dict{Task,Int}(), nothing, 0)
    end
end

const _db_locks      = Dict{String,_DBLock}()
const _db_locks_lock = ReentrantLock()

function _db_lock(db_path::String)
    key = abspath(normpath(db_path))
    lock(_db_locks_lock) do
        get!(_DBLock, _db_locks, key)
    end
end

# Returns true when a read slot was taken. A task that already holds the write side
# has exclusive access anyway, and taking the read side would deadlock against itself,
# so it is waved through with nothing to release.
function _acquire_read!(l::_DBLock)
    task = current_task()
    lock(l.guard) do
        l.writer === task && return false
        while !isnothing(l.writer)
            wait(l.ready)
        end
        l.readers += 1
        l.depths[task] = get(l.depths, task, 0) + 1
        return true
    end
end

function _release_read!(l::_DBLock)
    task = current_task()
    lock(l.guard) do
        l.readers -= 1
        depth = l.depths[task] - 1
        depth == 0 ? delete!(l.depths, task) : (l.depths[task] = depth)
        l.readers == 0 && notify(l.ready; all=true)
        return nothing
    end
end

function _acquire_write!(l::_DBLock)
    task = current_task()
    lock(l.guard) do
        if l.writer === task
            l.wdepth += 1
            return nothing
        end
        # A read hold cannot be upgraded: this task would have to wait for its own read
        # slot to drain. Say so rather than hang, since DuckDB would refuse the second
        # handle in any case.
        haskey(l.depths, task) && error("with_results_db_write cannot be nested inside " *
                                        "with_results_db on the same database")
        while !isnothing(l.writer) || l.readers > 0
            wait(l.ready)
        end
        l.writer = task
        l.wdepth = 1
        return nothing
    end
end

function _release_write!(l::_DBLock)
    lock(l.guard) do
        l.wdepth -= 1
        if l.wdepth == 0
            l.writer = nothing
            notify(l.ready; all=true)
        end
        return nothing
    end
end

# Run `f` with the database at `db_path` held for writing (exclusive) or reading
# (shared).
function _with_db_lock(f::Function, db_path::String, write::Bool)
    l = _db_lock(db_path)
    if write
        _acquire_write!(l)
        try
            return f()
        finally
            _release_write!(l)
        end
    else
        held = _acquire_read!(l)
        try
            return f()
        finally
            held && _release_read!(l)
        end
    end
end

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
    # Recreating the file is the most destructive operation there is on it, so it takes
    # the writer lock for the whole of its work, readers included.
    _with_db_lock(db_path, true) do
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
Ensures the connection and DB are closed after use. Readers share the database with
one another but are excluded while a writer holds it.
"""
function with_results_db(f::Function, merge_dir::String)
    db_path = joinpath(merge_dir, "results.duckdb")
    _with_db_lock(db_path, false) do
        # Checked under the lock: a writer may be recreating the file.
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
end

"""
    with_results_db_write(f, merge_dir)

Open the DuckDB database in read-write mode and pass the connection to `f`.
Use this for mutations (CREATE TABLE, DROP TABLE) only; prefer `with_results_db`
for all read operations to avoid unintentional writes. The writer holds the database
exclusively for the duration of `f`, so no other reader or writer of the same file can
run concurrently.
"""
function with_results_db_write(f::Function, merge_dir::String)
    db_path = joinpath(merge_dir, "results.duckdb")
    _with_db_lock(db_path, true) do
        # Checked under the lock: another writer may have been recreating the file.
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

end
