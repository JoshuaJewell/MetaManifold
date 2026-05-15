module FuncDBAnnotation

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export load_funcdb, annotate_table, append_funcdb_entry

using DataFrames, CSV, Logging, Dates

## Constants
# FuncDB value columns to output column names.
const FUNCDB_VALUE_COLS = (
    :Function,
    :Detailed_function,
    :Associated_organism,
    :Associated_material,
    :Environment,
    :Potential_human_pathogen,
    :Comment,
    :Reference,
)

const FUNCDB_OUTPUT_COLS = [
    "function",
    "detailed_function",
    "assoc_organism",
    "assoc_material",
    "environment",
    "human_pathogen",
    "comment",
    "reference",
]

# Rank hierarchy from finest to coarsest.
# Each entry: (rank, FuncDB column, VSEARCH merged column, DADA2 merged column).
# Subdivision is in merged tables but absent from FuncDB and is skipped.
const RANK_HIERARCHY = [
    (rank="species",    funcdb=:Species,    vsearch="Species",    dada2="Species_dada2"),
    (rank="genus",      funcdb=:Genus,      vsearch="Genus",      dada2="Genus_dada2"),
    (rank="family",     funcdb=:family,     vsearch="Family",     dada2="Family_dada2"),
    (rank="order",      funcdb=:order,      vsearch="Order",      dada2="Order_dada2"),
    (rank="class",      funcdb=:class,      vsearch="Class",      dada2="Class_dada2"),
    (rank="division",   funcdb=:division,   vsearch="Division",   dada2="Division_dada2"),
    (rank="supergroup", funcdb=:supergroup, vsearch="Supergroup", dada2="Supergroup_dada2"),
]

# VSEARCH-only columns dropped from DADA2-annotated output.
# Maps rank name to its index in RANK_HIERARCHY (1 = finest = species).
# Used in load_funcdb to enforce Assignment_level as a ceiling when building maps.
const _RANK_INDEX = Dict(r.rank => i for (i, r) in enumerate(RANK_HIERARCHY))

const VSEARCH_ONLY_COLS = Set([
    "Pident", "Accession", "rRNA", "Organellum", "specimen",
    "Domain", "Supergroup", "Division", "Subdivision", "Class", "Order",
    "Family", "Genus", "Species",
])


const _SUPPORTED_MAX_RANKS = Set(String[r.rank for r in RANK_HIERARCHY])

## Internal helpers
# Detect integer sample-count columns from a DataFrame (excludes *_boot columns).
function _sample_count_cols(df::DataFrame)
    result = String[]
    for col in names(df)
        endswith(col, "_boot") && continue
        T = nonmissingtype(eltype(df[!, col]))
        T <: Integer && push!(result, col)
    end
    result
end

# Try to extract subgroup labels from sample column names.
# Supports PRIMER-SUBGROUP-NUMBER (V4-C-06) and ID_TISSUE_METHOD (10c_m) patterns.
# Returns Dict{subgroup => [col, ...]}; empty if no pattern matches.
function _sample_subgroups(col_names::Vector{String})
    subgroups = Dict{String,Vector{String}}()
    # Pattern 1: dash-separated (V4-C-06)
    for col in col_names
        m = match(r"^[A-Za-z0-9]+-([A-Za-z]+)-\d+$", col)
        isnothing(m) && continue
        push!(get!(subgroups, m.captures[1], String[]), col)
    end
    !isempty(subgroups) && return subgroups
    # Pattern 2: underscore-separated (10c_m) - subgroup is the letter before underscore
    for col in col_names
        m = match(r"^\d+([A-Za-z])_[A-Za-z]$", col)
        isnothing(m) && continue
        push!(get!(subgroups, uppercase(m.captures[1]), String[]), col)
    end
    subgroups
end

function _colsum(df::DataFrame, cols::Vector{String})
    n = nrow(df)
    totals = zeros(Int64, n)
    for c in cols
        col_vals = df[!, c]
        for i in 1:n
            v = col_vals[i]
            ismissing(v) || (totals[i] += Int64(v))
        end
    end
    totals
end

# Compute consensus rank by comparing VSEARCH and DADA2 taxonomy in source_df.
# Returns a String vector with the finest rank where both methods agree ("species",
# "genus", etc.) or "" if they never agree or one method is absent.
function _compute_consensus_rank(source_df::DataFrame)
    n = nrow(source_df)
    consensus = fill("", n)
    df_cols = Set(names(source_df))
    pairs = [(r.rank, r.vsearch, r.dada2) for r in RANK_HIERARCHY
             if r.vsearch in df_cols && r.dada2 in df_cols]
    isempty(pairs) && return consensus

    for i in 1:n
        for (rank, vs_col, d2_col) in pairs   # finest -> coarsest
            vs = _normalize_key(source_df[i, vs_col])
            d2 = _normalize_key(source_df[i, d2_col])
            (isempty(vs) || isempty(d2)) && continue
            if vs == d2
                consensus[i] = rank
                break
            end
        end
    end
    consensus
end

# Extended rank index for bootstrap score: includes Domain (coarser than supergroup).
const _SCORE_RANK_INDEX = merge(_RANK_INDEX, Dict("domain" => length(RANK_HIERARCHY) + 1))

# Compute a 0-1 confidence score from bootstrap values and Pident.
#
# Formula:  score = mean_bootstrap / 100  *  pident / 100
#
# mean_bootstrap is the mean over ALL _boot columns present in the table.
# Bootstrap values at ranks FINER than the consensus_rank are treated as 0,
# so coarse consensus naturally produces a low score even when the bootstraps
# at the consensus rank itself are high.
#
# Returns missing when consensus_rank is empty or no metrics exist.
function _compute_consensus_score(source_df::DataFrame, consensus_rank::Vector{String})
    n = nrow(source_df)
    score = Vector{Union{Missing,Float64}}(missing, n)
    col_names = names(source_df)
    has_pident = "Pident" in col_names

    # Discover all *_boot columns and map to rank index.
    boot_info = Tuple{String,Int}[]   # (column_name, rank_index)
    for col in col_names
        endswith(col, "_boot") || continue
        rank_name = lowercase(col[1:end-5])
        idx = get(_SCORE_RANK_INDEX, rank_name, nothing)
        isnothing(idx) && continue
        push!(boot_info, (col, idx))
    end

    n_boot = length(boot_info)
    (n_boot == 0 && !has_pident) && return score

    for i in 1:n
        cr = consensus_rank[i]
        isempty(cr) && continue
        cons_idx = get(_RANK_INDEX, cr, nothing)
        isnothing(cons_idx) && continue

        # Mean bootstrap: zero out ranks finer than consensus.
        mean_boot = if n_boot > 0
            boot_sum = 0.0
            for (col, ridx) in boot_info
                ridx >= cons_idx || continue          # finer -> 0
                b = source_df[i, col]
                (ismissing(b) || isnothing(b)) && continue
                boot_sum += Float64(b)
            end
            boot_sum / n_boot                         # divide by ALL boot cols
        else
            100.0   # no bootstrap data -> assume 100 so score degrades to pident alone
        end

        pident = if has_pident
            p = source_df[i, "Pident"]
            (ismissing(p) || isnothing(p)) ? 100.0 : Float64(p)
        else
            100.0   # no pident -> assume 100 so score degrades to bootstrap alone
        end

        score[i] = round(mean_boot / 100.0 * pident / 100.0; digits=4)
    end
    score
end

# Append per-subgroup total columns and a grand total column to df in-place.
# Uses integer-type detection for the grand total and name-pattern matching for subgroups.
function _add_totals!(df::DataFrame)
    all_cols = _sample_count_cols(df)
    isempty(all_cols) && return

    subgroups = _sample_subgroups(all_cols)
    for sg in sort(collect(keys(subgroups)))
        df[!, "total_$sg"] = _colsum(df, subgroups[sg])
    end

    df[!, "total"] = _colsum(df, all_cols)
end

"""
    _normalize_key(val) -> String

Lowercase, trimmed string. Returns empty string for missing, blank, or "blank".
"""
function _normalize_key(val)::String
    (ismissing(val) || isnothing(val)) && return ""
    s = strip(lowercase(string(val)))
    s == "blank" && return ""
    return s
end

"""
    _extract_values(row) -> NamedTuple

Pull the FuncDB value columns from a DataFrame row into a NamedTuple of Strings.
"""
function _extract_values(row)
    vals = map(FUNCDB_VALUE_COLS) do col
        v = hasproperty(row, col) ? getproperty(row, col) : missing
        (ismissing(v) || isnothing(v)) ? "" : strip(string(v))
    end
    return NamedTuple{FUNCDB_VALUE_COLS}(vals)
end

## load_funcdb
"""
    load_funcdb(path) -> Dict{String, Dict{String, NamedTuple}}

Load `FuncDB_species.csv` and build a lookup map per taxonomic rank.

Returns a Dict mapping rank name (e.g. "species", "genus", "family") to a
Dict of normalised taxon key to NamedTuple of FuncDB values.

Duplicate species keys log a warning; duplicate keys at higher ranks are
expected (many species per genus, etc.) and silently keep the first entry.
"""
function load_funcdb(path::String)
    isfile(path) || error("FuncDB file not found: $path")

    df = CSV.read(path, DataFrame; stringtype=String)

    maps = Dict{String, Dict{String, NamedTuple}}(
        r.rank => Dict{String, NamedTuple}() for r in RANK_HIERARCHY
    )

    for row in eachrow(df)
        vals = _extract_values(row)

        # Assignment_level is the finest rank at which the annotation was made.
        # Only populate maps for ranks at or finer than this level; indexing into
        # coarser maps would let a genus-level entry match via a shared family name.
        assignment_level = _normalize_key(
            hasproperty(row, :Assignment_level) ? getproperty(row, :Assignment_level) : missing
        )
        max_idx = get(_RANK_INDEX, assignment_level, length(RANK_HIERARCHY))

        for (i, r) in enumerate(RANK_HIERARCHY)
            i > max_idx && break
            key = _normalize_key(hasproperty(row, r.funcdb) ? getproperty(row, r.funcdb) : missing)
            isempty(key) && continue
            if haskey(maps[r.rank], key)
                r.rank == "species" && @warn "Duplicate species key in FuncDB, keeping first" key=key
            else
                maps[r.rank][key] = vals
            end
        end
    end

    @info "FuncDB loaded" species=length(maps["species"]) genera=length(maps["genus"])
    return maps
end

## annotate_table
"""
    annotate_table(source_df, taxonomy_source, funcdb_path) -> DataFrame

Annotate a taxonomy DataFrame with FuncDB functional annotations.

- `taxonomy_source`: "VSEARCH" or "DADA2"
- Matching walks the rank hierarchy from species down to supergroup, using
  the first match found.
- Columns from the other taxonomy source are dropped from the output.
- Appends funcdb_* value columns plus `match_rank`.
"""
function annotate_table(source_df::DataFrame, taxonomy_source::String, funcdb_path::String;
                        max_rank::String="species")::DataFrame
    taxonomy_source in ("VSEARCH", "DADA2") ||
        error("Invalid taxonomy_source: '$taxonomy_source'. Must be VSEARCH or DADA2.")
    max_rank = lowercase(strip(max_rank))
    max_rank in _SUPPORTED_MAX_RANKS ||
        error("Invalid max_rank: '$max_rank'. Must be one of $(join(sort(collect(_SUPPORTED_MAX_RANKS)), ", ")).")

    merged_col_field = taxonomy_source == "VSEARCH" ? :vsearch : :dada2
    max_rank_index = _RANK_INDEX[max_rank]

    maps = load_funcdb(funcdb_path)

    nrows = nrow(source_df)

    out_vals    = [Vector{String}(undef, nrows) for _ in 1:length(FUNCDB_OUTPUT_COLS)]
    match_rank  = Vector{String}(undef, nrows)

    for i in 1:nrows
        row = source_df[i, :]

        matched_vals = nothing
        matched_rank = "unmatched"

        for r in RANK_HIERARCHY[max_rank_index:end]
            col = getfield(r, merged_col_field)
            # Skip if merged table doesn't have this rank column
            hasproperty(source_df, Symbol(col)) || continue

            key = _normalize_key(row[Symbol(col)])
            isempty(key) && continue

            if haskey(maps[r.rank], key)
                matched_vals = maps[r.rank][key]
                matched_rank = r.rank
                break
            end
        end

        for (j, col_sym) in enumerate(FUNCDB_VALUE_COLS)
            out_vals[j][i] = isnothing(matched_vals) ? "" : string(matched_vals[col_sym])
        end

        match_rank[i] = matched_rank
    end

    result = copy(source_df)

    # Drop columns from the other taxonomy source
    if taxonomy_source == "VSEARCH"
        drop = filter(c -> endswith(c, "_dada2") || endswith(c, "_boot"), names(result))
    else
        drop = filter(c -> c in VSEARCH_ONLY_COLS, names(result))
    end
    isempty(drop) || select!(result, Not(drop))

    finer_ranks = RANK_HIERARCHY[1:max(0, max_rank_index - 1)]
    finer_cols = String[]
    for r in finer_ranks
        source_col = taxonomy_source == "VSEARCH" ? r.vsearch : r.dada2
        push!(finer_cols, source_col)
        taxonomy_source == "DADA2" && push!(finer_cols, replace(source_col, "_dada2" => "_boot"))
    end
    finer_cols = filter(c -> c in names(result), unique(finer_cols))
    isempty(finer_cols) || select!(result, Not(finer_cols))

    # Append FuncDB value columns
    for (j, col_name) in enumerate(FUNCDB_OUTPUT_COLS)
        result[!, col_name] = out_vals[j]
    end

    result[!, "match_rank"] = match_rank
    cons_rank = _compute_consensus_rank(source_df)
    result[!, "consensus_rank"]  = cons_rank
    result[!, "consensus_score"] = _compute_consensus_score(source_df, cons_rank)
    result[!, "Contamination"] = fill("unassigned", nrows)
    result[!, "BLAST Assignment"] = fill("", nrows)

    _add_totals!(result)

    return result
end

## append_funcdb_entry
"""
    append_funcdb_entry(path, entry::Dict; modified_by="") -> NamedTuple

Prepend a single entry to the FuncDB CSV file (inserted after the header).
Newer entries at the top take precedence during annotation, so edits naturally
override older rows without deleting them from the ledger.

`entry` must contain at least one taxonomy key (Species, Genus, etc.) and at
least `Function`. Missing columns default to empty strings.
Returns a NamedTuple of the written row.
"""
function append_funcdb_entry(path::String, entry::Dict; modified_by::String="")
    isfile(path) || error("FuncDB file not found: $path")

    existing = CSV.read(path, DataFrame; stringtype=String)
    existing_cols = Symbol.(names(existing))

    # Build the row, filling missing keys with ""
    row = Dict{Symbol, String}()
    for col in existing_cols
        row[col] = get(entry, String(col), get(entry, col, ""))
    end
    row[:Modified_by]   = modified_by
    row[:Modified_date] = string(today())

    # Validate: at least one taxonomy key and a main function
    has_taxon = any(!isempty(get(row, Symbol(r.rank == "species" ? "Species" :
                    r.rank == "genus" ? "Genus" : r.rank), "")) for r in RANK_HIERARCHY)
    has_taxon || error("Entry must have at least one taxonomy key")
    isempty(get(row, :Function, "")) && error("Entry must have Function")

    new_row = DataFrame(; (col => [get(row, col, "")] for col in existing_cols)...)
    result = vcat(new_row, existing)
    CSV.write(path, result)

    @info "FuncDB entry prepended" species=get(row, :Species, "") genus=get(row, :Genus, "") modified_by
    return NamedTuple{Tuple(existing_cols)}(Tuple(get(row, c, "") for c in existing_cols))
end

end
