# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: functional annotation (FuncDB) for listing, generation, querying,
# distinct-value lookup, and contamination tagging.
using JSON3, CSV, DataFrames, OrderedCollections, DuckDB, DBInterface, Dates

const FUNCDB_PATH = joinpath(dirname(dirname(dirname(@__DIR__))), "databases", "FuncDB_species.csv")
const BLAST_ASSIGNMENT_COLUMN = "BLAST Assignment"

function _annotation_max_rank(study::String, run::String;
                              group::Union{String,Nothing}=nothing)
    cfg = _resolve_config(study, run, group)
    raw = get(get(cfg, "annotation.max_rank", (; value="species", source="default")), :value, "species")
    value = lowercase(strip(string(raw)))
    value in FuncDBAnnotation._SUPPORTED_MAX_RANKS || return nothing
    value
end

_annotation_required_col(source::String, max_rank::String) =
    _matched_taxon_column(source, max_rank)

"""
    _require_max_rank_col(study, run, source; group) -> (max_rank, required_col) or HTTP error response

Validate annotation.max_rank config and resolve the required taxonomy column.
Returns an HTTP error response on failure.
"""
function _require_max_rank_col(study::String, run::String, source::String;
                               group::Union{String,Nothing}=nothing)
    max_rank = _annotation_max_rank(study, run; group)
    isnothing(max_rank) && return json_error(400, "invalid_annotation_max_rank",
        "annotation.max_rank must be one of species, genus, family, order, class, division, or supergroup")

    required_col = _annotation_required_col(source, max_rank)
    isnothing(required_col) && return json_error(400, "invalid_annotation_max_rank",
        "No taxonomy column mapping exists for annotation.max_rank='$max_rank'")

    (max_rank, required_col)
end

function _validate_source(source::String)
    source in ("VSEARCH", "DADA2") || return false
    true
end

function _annotation_dir(study::String, run::String, source::String;
                         group::Union{String,Nothing}=nothing)
    joinpath(_run_project_dir(study, run; group), "annotated", source)
end

function _annotation_db_path(study::String, run::String, source::String;
                             group::Union{String,Nothing}=nothing)
    joinpath(_annotation_dir(study, run, source; group), "annotations.duckdb")
end

function _require_study_run_source(study::String, run::String, source::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                 "Study '$study' not found")
    run in _all_run_names(study) || return json_error(404, "run_not_found",
                                                      "Run '$run' not found")
    _validate_source(source) || return json_error(400, "invalid_source",
                                                  "Source must be 'VSEARCH' or 'DADA2'")
    nothing
end

function _with_annotation_db(f, study::String, run::String, source::String;
                             group::Union{String,Nothing}=nothing, readonly::Bool=true)
    ann_db_path = _annotation_db_path(study, run, source; group)
    isfile(ann_db_path) || return json_error(404, "no_annotations",
                                             "No annotation database found for $source")

    # Open the DB. Only failures HERE (unreadable/corrupt file) justify
    # destroying and rebuilding it from CSV; application errors from `f(con)`
    # must NOT trigger a rebuild, or unrelated bugs would silently clobber any
    # annotations that live in the DuckDB but have not been re-synced to CSV.
    local db, con
    try
        db = DuckDB.DB(ann_db_path; readonly)
        con = DBInterface.connect(db)
    catch e
        ann_dir = _annotation_dir(study, run, source; group)
        csvs = filter(f -> endswith(f, ".csv"), readdir(ann_dir; join=true))
        isempty(csvs) && rethrow()
        @warn "Annotation DB unreadable, rebuilding from CSV" ann_db_path exception=(e, catch_backtrace())
        rm(ann_db_path; force=true)
        rebuild_db  = DuckDB.DB(ann_db_path)
        rebuild_con = DBInterface.connect(rebuild_db)
        try
            for csv_path in csvs
                tname = basename(csv_path)[1:end-4]
                DBInterface.execute(rebuild_con,
                    "CREATE OR REPLACE TABLE \"$(tname)\" AS SELECT * FROM read_csv_auto('$(csv_path)', auto_detect=true, types={'Contamination': 'VARCHAR', '$(BLAST_ASSIGNMENT_COLUMN)': 'VARCHAR'})")
            end
        finally
            DBInterface.close!(rebuild_con)
            close(rebuild_db)
        end
        # Reopen in the caller's requested mode.
        db  = DuckDB.DB(ann_db_path; readonly)
        con = DBInterface.connect(db)
    end

    try
        f(con)
    finally
        DBInterface.close!(con)
        close(db)
    end
end

function _annotation_status(csv_path::String, merged_csv_path::String, funcdb_path::String;
                            config_paths::Vector{String}=String[])
    isfile(csv_path) || return "missing"
    ann_mtime = mtime(csv_path)
    merged_mtime = isfile(merged_csv_path) ? mtime(merged_csv_path) : 0.0
    funcdb_mtime = isfile(funcdb_path) ? mtime(funcdb_path) : 0.0
    (ann_mtime < merged_mtime || ann_mtime < funcdb_mtime) && return "stale"
    for cp in config_paths
        isfile(cp) && mtime(cp) > ann_mtime && return "stale"
    end
    "fresh"
end

function _contamination_stats(con, table::String)
    df = DataFrame(DBInterface.execute(con, "SELECT * FROM \"$table\""))
    count_cols = _sample_count_columns(con, table)
    _contamination_stats_from_df(df, count_cols)
end

function _contamination_stats_from_df(df::DataFrame, count_cols::Vector{String})
    tally = Dict{String,NamedTuple}()
    for status in ("yes", "no", "unassigned")
        mask = df[!, "Contamination"] .== status
        n_rows  = sum(mask)
        n_reads = isempty(count_cols) ? 0 :
                  sum(count_cols) do col
                      sum(coalesce.(df[mask, col], 0))
                  end
        tally[status] = (; rows=n_rows, reads=Int(coalesce(n_reads, 0)))
    end
    total_rows  = sum(v.rows  for v in values(tally))
    total_reads = sum(v.reads for v in values(tally))
    (; yes=tally["yes"], no=tally["no"], unassigned=tally["unassigned"],
       total=(; rows=total_rows, reads=total_reads))
end

function _annotation_catalog(study::String, run::String, source::String;
                             group::Union{String,Nothing}=nothing)
    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return Any[]

    result = _require_max_rank_col(study, run, source; group)
    result isa Tuple || return result
    (_, required_col) = result

    ann_dir = _annotation_dir(study, run, source; group)
    ann_db_path = _annotation_db_path(study, run, source; group)

    ann_table_rows = Dict{String,Int}()
    if isfile(ann_db_path)
        try
            _with_annotation_db(study, run, source; group) do ann_con
                ann_tables = Set(string.(DataFrame(DBInterface.execute(ann_con, "SHOW TABLES")).name))
                for tname in ann_tables
                    ann_table_rows[tname] = only(DataFrame(DBInterface.execute(
                        ann_con, "SELECT COUNT(*) AS n FROM \"$tname\""))).n
                end
            end
        catch e
            @warn "Failed to read annotation DB, falling back to CSV" source exception=(e, catch_backtrace())
            for f in filter(f -> endswith(f, ".csv"), readdir(ann_dir; join=false))
                tname = f[1:end-4]
                try ann_table_rows[tname] = countlines(joinpath(ann_dir, f)) - 1 catch; end
            end
        end
    end

    # Collect pipeline.yml paths whose changes affect annotation output
    # (annotation.max_rank lives in the config cascade).
    cfg_paths = String[]
    data_dir = ServerState.data_dir()
    root = dirname(data_dir)
    for p in [joinpath(root, "config", "defaults", "pipeline.yml"),
              joinpath(root, "config", "pipeline.yml"),
              joinpath(data_dir, study, "pipeline.yml")]
        push!(cfg_paths, p)
    end
    if !isnothing(group)
        push!(cfg_paths, joinpath(data_dir, study, group, "pipeline.yml"))
        push!(cfg_paths, joinpath(data_dir, study, group, run, "pipeline.yml"))
    else
        push!(cfg_paths, joinpath(data_dir, study, run, "pipeline.yml"))
    end

    with_results_db(dir) do con
        table_names = string.(DataFrame(DBInterface.execute(con, "SHOW TABLES")).name)
        catalog = Any[]

        for tname in table_names
            cols = _duckdb_columns(con, tname)
            col_set = Set(cols)
            required_col in col_set || continue

            csv_path = joinpath(ann_dir, tname * ".csv")
            merged_csv_path = joinpath(dir, tname * ".csv")
            status = _annotation_status(csv_path, merged_csv_path, FUNCDB_PATH;
                                        config_paths=cfg_paths)
            rows = get(ann_table_rows, tname, nothing)
            generated_at = status == "missing" ? nothing : unix2datetime(mtime(csv_path))

            push!(catalog, (; table=tname, source, status, rows, generated_at))
        end

        catalog
    end
end

function _load_source_table(study::String, run::String, table::String;
                            group::Union{String,Nothing}=nothing)
    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return nothing

    with_results_db(dir) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return nothing
        DataFrame(DBInterface.execute(con, "SELECT * FROM \"$table\""))
    end
end

function _write_annotation_output!(study::String, run::String, source::String,
                                   table::String, df::DataFrame;
                                   group::Union{String,Nothing}=nothing)
    ann_dir = _annotation_dir(study, run, source; group)
    mkpath(ann_dir)

    csv_path = joinpath(ann_dir, table * ".csv")
    CSV.write(csv_path, df)

    db = DuckDB.DB(_annotation_db_path(study, run, source; group))
    con = DBInterface.connect(db)
    try
        # Force Contamination and BLAST Assignment to VARCHAR so DuckDB doesn't
        # misdetect them as boolean when all values happen to be "yes"/"no"/true/false.
        DBInterface.execute(con,
            "CREATE OR REPLACE TABLE \"$(table)\" AS SELECT * FROM read_csv_auto('$(csv_path)', auto_detect=true, types={'Contamination': 'VARCHAR', '$(BLAST_ASSIGNMENT_COLUMN)': 'VARCHAR'})")
    finally
        DBInterface.close!(con)
        close(db)
    end

    csv_path
end

function _annotation_response(table::String, source::String, output_path::String, rows::Int;
                              contamination_stats=nothing)
    generated_at = unix2datetime(mtime(output_path))
    if isnothing(contamination_stats)
        (; table, source, status="fresh", rows, output_path, generated_at)
    else
        (; table, source, status="fresh", rows, output_path, generated_at,
           contamination_stats)
    end
end

function _annotation_select_expr(columns::Vector{String})
    BLAST_ASSIGNMENT_COLUMN in columns && return "*"
    "*, '' AS \"$(BLAST_ASSIGNMENT_COLUMN)\""
end

function _annotation_response_columns(columns::Vector{String})
    BLAST_ASSIGNMENT_COLUMN in columns ? columns : [columns; BLAST_ASSIGNMENT_COLUMN]
end

function _ensure_annotation_column!(con, table::String, column::String)
    columns = _duckdb_columns(con, table)
    column in columns && return false
    DBInterface.execute(con,
        """ALTER TABLE "$(table)"
           ADD COLUMN "$(column)" VARCHAR DEFAULT ''""")
    true
end

function _sync_annotation_csv_assignment!(csv_path::String, sequence::String, assignment::String)
    isfile(csv_path) || return

    csv_df = CSV.read(csv_path, DataFrame; stringtype=String)
    BLAST_ASSIGNMENT_COLUMN in names(csv_df) || (csv_df[!, BLAST_ASSIGNMENT_COLUMN] = fill("", nrow(csv_df)))
    seq_col = Analysis.sequence_column_name(names(csv_df))
    isnothing(seq_col) && return

    mask = string.(coalesce.(csv_df[!, seq_col], "")) .== sequence
    csv_df[mask, BLAST_ASSIGNMENT_COLUMN] .= assignment
    CSV.write(csv_path, csv_df)
end

function _generate_annotation!(study::String, run::String, source::String, table::String;
                               group::Union{String,Nothing}=nothing)
    source_df = _load_source_table(study, run, table; group)
    isnothing(source_df) && return json_error(404, "table_not_found",
                                              "Table '$table' not found in results database")

    result = _require_max_rank_col(study, run, source; group)
    result isa Tuple || return result
    (max_rank, required_col) = result

    col_set = Set(names(source_df))
    required_col in col_set || return json_error(400, "missing_taxonomy_columns",
        "Table '$table' is missing required column '$required_col' for $source annotation at rank '$max_rank'")

    annotated_df = try
        FuncDBAnnotation.annotate_table(source_df, source, FUNCDB_PATH; max_rank)
    catch e
        @error "Annotation failed" exception=(e, catch_backtrace())
        return json_error(500, "annotation_failed", "Annotation failed: $(sprint(showerror, e))")
    end

    # Preserve user-edited Contamination and BLAST Assignment from the existing
    # annotation by joining on the sequence column.
    try
        ann_csv = joinpath(_annotation_dir(study, run, source; group), table * ".csv")
        if isfile(ann_csv)
            old_df = CSV.read(ann_csv, DataFrame; stringtype=String)
            seq_col = nothing
            for c in names(old_df)
                lowercase(c) == "sequence" && (seq_col = c; break)
            end
            if !isnothing(seq_col) && seq_col in names(annotated_df)
                old_cols = [seq_col]
                "Contamination" in names(old_df) && push!(old_cols, "Contamination")
                BLAST_ASSIGNMENT_COLUMN in names(old_df) && push!(old_cols, BLAST_ASSIGNMENT_COLUMN)
                if length(old_cols) > 1
                    edits = select(old_df, old_cols)
                    "Contamination" in names(edits) &&
                        rename!(edits, "Contamination" => "_old_Contamination")
                    BLAST_ASSIGNMENT_COLUMN in names(edits) &&
                        rename!(edits, BLAST_ASSIGNMENT_COLUMN => "_old_BLAST")
                    merged = leftjoin(annotated_df, edits; on=seq_col)
                    if "_old_Contamination" in names(merged)
                        for i in 1:nrow(merged)
                            old_val = coalesce(merged[i, "_old_Contamination"], "")
                            if old_val in ("yes", "no")
                                merged[i, "Contamination"] = old_val
                            end
                        end
                        select!(merged, Not("_old_Contamination"))
                    end
                    if "_old_BLAST" in names(merged)
                        for i in 1:nrow(merged)
                            old_val = coalesce(merged[i, "_old_BLAST"], "")
                            if !isempty(old_val)
                                merged[i, BLAST_ASSIGNMENT_COLUMN] = old_val
                            end
                        end
                        select!(merged, Not("_old_BLAST"))
                    end
                    annotated_df = merged
                end
            end
        end
    catch e
        @warn "Failed to preserve user edits, starting fresh" exception=(e, catch_backtrace())
    end

    output_path = _write_annotation_output!(study, run, source, table, annotated_df; group)
    rows = nrow(annotated_df)
    @info "Generated annotation" table source rows output_path
    json(_annotation_response(table, source, output_path, rows))
end

function _annotation_query(con, table::String, body)
    columns = _duckdb_columns(con, table)
    isempty(columns) && return json_error(404, "table_not_found",
                                          "Table '$table' not found in annotation database")
    _duckdb_paginated_query(con, table, body;
        select_expr=_annotation_select_expr(columns),
        response_columns=_annotation_response_columns(columns))
end

function _annotation_distinct(con, table::String, column::String, body)
    _duckdb_distinct(con, table, column, body;
        extra_guard=(col, cols) -> begin
            col == BLAST_ASSIGNMENT_COLUMN && !(col in cols) &&
                return json((; column=col, type="text", values=String[], count=0, truncated=false))
            nothing
        end)
end

function _matched_taxon_column(source::String, rank::String)
    rank_entry = findfirst(r -> r.rank == rank, FuncDBAnnotation.RANK_HIERARCHY)
    isnothing(rank_entry) && return nothing
    entry = FuncDBAnnotation.RANK_HIERARCHY[rank_entry]
    source == "VSEARCH" ? entry.vsearch : entry.dada2
end

function _sync_annotation_csv!(csv_path::String, taxon_col::String, rank::String,
                               taxon::String, status::String)
    isfile(csv_path) || return

    csv_df = CSV.read(csv_path, DataFrame; stringtype=String)
    if !("Contamination" in names(csv_df)) || !(taxon_col in names(csv_df))
        return
    end

    mask = csv_df.match_rank .== rank .&&
           lowercase.(strip.(csv_df[!, taxon_col])) .== lowercase(strip(taxon))
    csv_df.Contamination[mask] .= status
    CSV.write(csv_path, csv_df)
end

## QUARANTINED: FuncDB annotation deactivated; code retained, see 2026-06-25 convergence work
# @get "/api/v1/studies/{study}/runs/{run}/annotations/{source}" function(req,
#                                                                         study::String,
#                                                                         run::String,
#                                                                         source::String)
#     err = _require_study_run_source(study, run, source)
#     !isnothing(err) && return err
#     result = _annotation_catalog(study, run, source; group=_req_group(req))
#     result isa HTTP.Response && return result
#     json(result)
# end

## QUARANTINED: FuncDB annotation deactivated; code retained, see 2026-06-25 convergence work
# @post "/api/v1/studies/{study}/runs/{run}/annotations/{source}/generate" function(req,
#                                                                                    study::String,
#                                                                                    run::String,
#                                                                                    source::String)
#     err = _require_study_run_source(study, run, source)
#     !isnothing(err) && return err
#     isfile(FUNCDB_PATH) || return json_error(400, "funcdb_missing",
#         "FuncDB database not found at expected path")
#
#     group = _req_group(req)
#     dir = _require_duckdb(study, run; group)
#     isnothing(dir) && return json_error(404, "no_results",
#         "No results database for run '$run' - run the pipeline first")
#
#     body = JSON3.read(String(req.body))
#     table = get(body, :table, nothing)
#     isnothing(table) && return json_error(400, "missing_table", "Body must include 'table'")
#     table = string(table)
#
#     _generate_annotation!(study, run, source, table; group)
# end

## QUARANTINED: FuncDB annotation deactivated; code retained, see 2026-06-25 convergence work
# @post "/api/v1/studies/{study}/runs/{run}/annotations/{source}/{table}/query" function(req,
#                                                                                         study::String,
#                                                                                         run::String,
#                                                                                         source::String,
#                                                                                         table::String)
#     err = _require_study_run_source(study, run, source)
#     !isnothing(err) && return err
#
#     body = JSON3.read(String(req.body))
#     _with_annotation_db(study, run, source; group=_req_group(req)) do con
#         _annotation_query(con, table, body)
#     end
# end

## Annotation distinct values
@post "/api/v1/studies/{study}/runs/{run}/annotations/{source}/{table}/distinct/{column}" function(req,
                                                                                                    study::String,
                                                                                                    run::String,
                                                                                                    source::String,
                                                                                                    table::String,
                                                                                                    column::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    body = length(req.body) > 0 ? JSON3.read(String(req.body)) : (;)
    _with_annotation_db(study, run, source; group=_req_group(req)) do con
        _annotation_distinct(con, table, column, body)
    end
end

## FuncDB entry creation
@post "/api/v1/funcdb/entries" function(req)
    isfile(FUNCDB_PATH) || return json_error(400, "funcdb_missing",
        "FuncDB database not found at expected path")

    body = JSON3.read(String(req.body))
    entry = Dict{String, String}()
    for (k, v) in pairs(body)
        k == :modified_by && continue
        entry[String(k)] = string(v)
    end

    modified_by = string(get(body, :modified_by, ""))

    row = try
        FuncDBAnnotation.append_funcdb_entry(FUNCDB_PATH, entry; modified_by)
    catch e
        return json_error(400, "invalid_entry", sprint(showerror, e))
    end

    json(row)
end

## Contamination update
# Sets Contamination for every row that shares the same matched rank and taxon.
@patch "/api/v1/studies/{study}/runs/{run}/annotations/{source}/{table}/contamination" function(req,
                                                                                                 study::String,
                                                                                                 run::String,
                                                                                                 source::String,
                                                                                                 table::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    rank = string(get(body, :rank, ""))
    taxon = string(get(body, :taxon, ""))
    status = string(get(body, :status, ""))

    isempty(rank) && return json_error(400, "missing_rank", "Body must include 'rank'")
    isempty(taxon) && return json_error(400, "missing_taxon", "Body must include 'taxon'")
    status in ("unassigned", "yes", "no") ||
        return json_error(400, "invalid_status",
                          "Status must be 'unassigned', 'yes', or 'no'")

    group = _req_group(req)

    taxon_col = _matched_taxon_column(source, rank)

    result = _with_annotation_db(study, run, source; group, readonly=false) do con
        columns = _duckdb_columns(con, table)
        col_set = Set(columns)
        "Contamination" in col_set || return json_error(400, "no_contamination_column",
            "Table '$table' has no Contamination column - regenerate the annotation")

        # For unmatched rows (or when the resolved column is missing), walk from
        # the configured max_rank through coarser ranks until we find one that
        # exists in the table. Protist tables often lack Species but have Genus.
        if isnothing(taxon_col) || !(taxon_col in col_set)
            max_rank = _annotation_max_rank(study, run; group)
            start_idx = isnothing(max_rank) ? 1 :
                get(FuncDBAnnotation._RANK_INDEX, max_rank, 1)
            taxon_col = nothing
            for r in FuncDBAnnotation.RANK_HIERARCHY[start_idx:end]
                candidate = source == "VSEARCH" ? r.vsearch : r.dada2
                if candidate in col_set
                    taxon_col = candidate
                    break
                end
            end
        end

        isnothing(taxon_col) && return json_error(400, "missing_taxon_column",
            "No usable taxonomy column found in table '$table'")

        DBInterface.execute(con,
            """UPDATE "$(table)"
               SET "Contamination" = \$1
               WHERE "match_rank" = \$2
                 AND LOWER(TRIM("$(taxon_col)")) = LOWER(TRIM(\$3))""",
            [status, rank, taxon])

        cnt = only(DataFrame(DBInterface.execute(con,
            """SELECT COUNT(*) AS n FROM "$(table)"
               WHERE "match_rank" = \$1
                 AND LOWER(TRIM("$(taxon_col)")) = LOWER(TRIM(\$2))""",
            [rank, taxon]))).n

        (; rows_affected=cnt, resolved_taxon_col=taxon_col)
    end
    result isa HTTP.Response && return result

    _sync_annotation_csv!(
        joinpath(_annotation_dir(study, run, source; group), table * ".csv"),
        result.resolved_taxon_col, rank, taxon, status)

    @info "Contamination updated" table rank taxon status rows_affected=result.rows_affected
    json((; table, rank, taxon, status, rows_affected=result.rows_affected))
end

## BLAST Assignment update
@patch "/api/v1/studies/{study}/runs/{run}/annotations/{source}/{table}/blast-assignment" function(req,
                                                                                                   study::String,
                                                                                                   run::String,
                                                                                                   source::String,
                                                                                                   table::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    body = JSON3.read(String(req.body))
    sequence = string(get(body, :sequence, ""))
    assignment = string(get(body, Symbol("blast_assignment"), ""))

    isempty(sequence) && return json_error(400, "missing_sequence", "Body must include 'sequence'")

    group = _req_group(req)
    result = _with_annotation_db(study, run, source; group, readonly=false) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return json_error(404, "table_not_found",
                                              "Table '$table' not found")
        seq_col = Analysis.sequence_column_name(columns)
        isnothing(seq_col) && return json_error(400, "missing_sequence_column",
            "Table '$table' has no sequence column")

        _ensure_annotation_column!(con, table, BLAST_ASSIGNMENT_COLUMN)
        DBInterface.execute(con,
            """UPDATE "$(table)"
               SET "$(BLAST_ASSIGNMENT_COLUMN)" = \$1
               WHERE "$(seq_col)" = \$2""",
            [assignment, sequence])

        cnt = only(DataFrame(DBInterface.execute(con,
            """SELECT COUNT(*) AS n FROM "$(table)"
               WHERE "$(seq_col)" = \$1""",
            [sequence]))).n

        (; rows_affected=cnt)
    end
    result isa HTTP.Response && return result

    _sync_annotation_csv_assignment!(
        joinpath(_annotation_dir(study, run, source; group), table * ".csv"),
        sequence, assignment)

    @info "BLAST Assignment updated" table sequence rows_affected=result.rows_affected
    json((; table, sequence, blast_assignment=assignment, rows_affected=result.rows_affected))
end

## Contamination stats
@get "/api/v1/studies/{study}/runs/{run}/annotations/{source}/{table}/contamination/stats" function(req,
                                                                                                     study::String,
                                                                                                     run::String,
                                                                                                     source::String,
                                                                                                     table::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    _with_annotation_db(study, run, source; group=_req_group(req)) do con
        columns = _duckdb_columns(con, table)
        isempty(columns) && return json_error(404, "table_not_found",
                                              "Table '$table' not found")
        "Contamination" in columns || return json_error(400, "no_contamination_column",
            "Table '$table' has no Contamination column")
        json(_contamination_stats(con, table))
    end
end

## Export annotation table as CSV
@get "/api/v1/studies/{study}/runs/{run}/annotations/{source}/{table}/export" function(req,
                                                                                        study::String,
                                                                                        run::String,
                                                                                        source::String,
                                                                                        table::String)
    err = _require_study_run_source(study, run, source)
    !isnothing(err) && return err

    group = _req_group(req)
    csv_path = joinpath(_annotation_dir(study, run, source; group), table * ".csv")
    isfile(csv_path) || return json_error(404, "not_found", "Annotation CSV not found for '$table'")

    HTTP.Response(200,
        ["Content-Type" => "text/csv",
         "Content-Disposition" => "attachment; filename=\"$(table).csv\""],
        body = read(csv_path))
end

