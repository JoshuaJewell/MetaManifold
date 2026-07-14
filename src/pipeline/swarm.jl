module OTUPipeline

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export swarm

    using CSV, DataFrames, YAML, Logging
    using ..PipelineTypes
    using ..PipelineLog
    using ..Config
    using ..Tools: tool_bin, _sq, _run_logged, _safe_optional_args

    _safe_int_count(v) = ismissing(v) ? 0 : Int(v)

    function _swarm_args(cfg::Dict)::String
        parts = String[]
        push!(parts, "-d $(get(cfg, "differences", 1))")
        threads = get(cfg, "threads", 0)
        threads > 0 && push!(parts, "-t $threads")
        extra = _safe_optional_args(cfg)
        isempty(extra) || push!(parts, extra)
        join(parts, " ")
    end

    ## Step 1: Write DADA2 ASVs as abundance-annotated FASTA for SWARM.
    # Reads the ASV count table to compute total abundance per ASV.
    function _write_annotated_fasta(asvs::ASVResult, swarm_dir::String)
        annotated = joinpath(swarm_dir, "asvs_annotated.fasta")

        # Read ASV fasta to get seq IDs and sequences
        seqs = Vector{Pair{String,String}}()
        open(asvs.fasta, "r") do io
            id = ""
            for line in eachline(io)
                if startswith(line, ">")
                    id = strip(line[2:end])
                else
                    push!(seqs, id => strip(line))
                end
            end
        end

        # Read count table for total abundance per ASV
        # asv_counts.csv has SeqName,Sequence,sample1,sample2,...
        counts_path = joinpath(dirname(asvs.taxonomy), "asv_counts.csv")
        if isfile(counts_path)
            df = CSV.read(counts_path, DataFrame)
            sample_cols = filter(c -> c ∉ ("SeqName", "Sequence", "sequence"), names(df))
            abundances = Dict{String,Int}()
            for row in eachrow(df)
                total = sum(_safe_int_count(row[c]) for c in sample_cols)
                abundances[string(row.SeqName)] = total
            end
        else
            # Fallback: use seqtab_nochim.csv (sequences as row names)
            abundances = Dict{String,Int}()
            df = CSV.read(asvs.count_table, DataFrame)
            # seqtab_nochim has sequences as first column, counts in remaining
            for (i, (id, _)) in enumerate(seqs)
                if i <= nrow(df)
                    sample_cols = names(df)[2:end]
                    total = sum(ismissing(df[i, c]) ? 0 : Int(df[i, c]) for c in sample_cols)
                    abundances[id] = total
                end
            end
        end

        open(annotated, "w") do io
            for (id, seq) in seqs
                size = get(abundances, id, 1)
                println(io, ">$(id);size=$(size)")
                println(io, seq)
            end
        end

        @info "SWARM: Wrote $(length(seqs)) annotated ASVs to $annotated"
        return annotated
    end

    ## Step 2: remove sequences containing ambiguous bases (N).
    # Swarm rejects any IUPAC ambiguity code; vsearch --fastx_filter drops them cleanly.
    function _filter_ns!(input::String, swarm_dir::String, vsearch_bin::String, log_dir::String)
        noN = joinpath(swarm_dir, "noN.fasta")
        _run_logged("$(vsearch_bin) --fastx_filter $(_sq(input)) --fastaout $(_sq(noN)) --fastq_maxns 0 --sizeout --quiet",
                    joinpath(log_dir, "filter_ns.log"))
        return noN
    end

    function _write_seed_fasta_from_uclust!(input_fasta::String, swarm_txt::String, seeds_raw::String)
        seed_ids = String[]
        open(swarm_txt, "r") do io
            for line in eachline(io)
                fields = split(line, '\t')
                length(fields) < 9 && continue
                fields[1] == "S" || continue
                push!(seed_ids, fields[9])
            end
        end

        wanted = Set(seed_ids)
        seqs = Dict{String,String}()
        open(input_fasta, "r") do io
            current_id = nothing
            current_seq = IOBuffer()
            for line in eachline(io)
                if startswith(line, ">")
                    if !isnothing(current_id) && (current_id in wanted)
                        seqs[current_id] = String(take!(current_seq))
                    else
                        truncate(current_seq, 0)
                    end
                    current_id = strip(line[2:end])
                else
                    write(current_seq, strip(line))
                end
            end
            if !isnothing(current_id) && (current_id in wanted)
                seqs[current_id] = String(take!(current_seq))
            end
        end

        open(seeds_raw, "w") do io
            for seed_id in seed_ids
                seq = get(seqs, seed_id, nothing)
                isnothing(seq) && error("SWARM: Seed '$seed_id' not found in $input_fasta")
                println(io, ">$seed_id")
                println(io, seq)
            end
        end
    end

    ## Step 3: SWARM clustering. Seeds are renamed otu1, otu2, ... for clean IDs.
    function _cluster!(input_fasta::String, swarm_dir::String, args::String,
                       swarm_bin::String, log_dir::String)
        seeds_raw = joinpath(swarm_dir, "seeds_raw.fasta")
        seeds     = joinpath(swarm_dir, "seeds.fasta")
        swarm_txt = joinpath(swarm_dir, "swarm.txt")
        _run_logged("$(swarm_bin) -z $(args) $(_sq(input_fasta)) --uclust-file $(_sq(swarm_txt))",
                    joinpath(log_dir, "swarm.log"))
        _write_seed_fasta_from_uclust!(input_fasta, swarm_txt, seeds_raw)
        # Rename to otu1, otu2, ... for consistent IDs across count table and taxonomy search.
        _run_logged("awk 'BEGIN{n=0}/^>/{printf \">otu%d\\n\",++n;next}{print}' $(_sq(seeds_raw)) > $(_sq(seeds))",
                    joinpath(log_dir, "rename.log"))
        return seeds
    end

    ## Parse SWARM uclust file into cluster membership.
    # Returns (cluster_members, otu_ids) and writes cluster_membership.csv.
    function _parse_clusters(swarm_dir::String, seeds::String)
        swarm_txt = joinpath(swarm_dir, "swarm.txt")
        cluster_members = Dict{Int,Vector{String}}()  # cluster_idx => [asv_id, ...]
        open(swarm_txt, "r") do io
            for line in eachline(io)
                fields = split(line, '\t')
                length(fields) < 9 && continue
                rec_type = fields[1]
                cluster  = parse(Int, fields[2])
                query_id = replace(fields[9], r";size=\d+$" => "")
                if rec_type == "S" || rec_type == "H"
                    push!(get!(cluster_members, cluster, String[]), query_id)
                end
            end
        end

        # Build OTU ID list from seeds fasta (otu1, otu2, ...)
        otu_ids = String[]
        open(seeds, "r") do io
            for line in eachline(io)
                startswith(line, ">") && push!(otu_ids, strip(line[2:end]))
            end
        end

        # Write cluster_membership.csv: ASV to OTU mapping
        membership_path = joinpath(swarm_dir, "cluster_membership.csv")
        open(membership_path, "w") do io
            println(io, "ASV,OTU")
            for (i, otu) in enumerate(otu_ids)
                for asv in get(cluster_members, i - 1, String[])
                    println(io, "$asv,$otu")
                end
            end
        end
        @info "SWARM: Wrote cluster membership to $membership_path"

        return cluster_members, otu_ids
    end

    ## Step 4: build OTU count table by aggregating ASV counts per OTU cluster.
    function _build_count_table_from_asvs!(swarm_dir::String, seeds::String,
                                            asvs::ASVResult)
        cluster_members, otu_ids = _parse_clusters(swarm_dir, seeds)

        # Read ASV count table
        counts_path = joinpath(dirname(asvs.taxonomy), "asv_counts.csv")
        df_counts = if isfile(counts_path)
            CSV.read(counts_path, DataFrame)
        else
            CSV.read(asvs.count_table, DataFrame)
        end

        sample_cols = filter(c -> c ∉ ("SeqName", "Sequence", "sequence"), names(df_counts))

        # Build per-ASV count lookup: asv_id => Dict(sample => count)
        asv_counts = Dict{String, Dict{String,Int}}()
        seq_col = "SeqName" in names(df_counts) ? "SeqName" : names(df_counts)[1]
        for row in eachrow(df_counts)
            id = string(row[seq_col])
            counts = Dict{String,Int}()
            for sc in sample_cols
                v = row[sc]
                counts[sc] = ismissing(v) ? 0 : Int(v)
            end
            asv_counts[id] = counts
        end

        # Aggregate: for each OTU (cluster), sum counts of member ASVs
        df = DataFrame(SeqName = otu_ids)
        # Strip suffixes from sample column names to match merge_taxa behaviour
        clean_samples = [replace(sc, r"_R[12]_filt\.fastq\.gz$" => "") for sc in sample_cols]
        for (sc, cs) in zip(sample_cols, clean_samples)
            col_data = Int[]
            for (i, _) in enumerate(otu_ids)
                members = get(cluster_members, i - 1, String[])
                total = sum(get(get(asv_counts, m, Dict{String,Int}()), sc, 0) for m in members; init=0)
                push!(col_data, total)
            end
            df[!, cs] = col_data
        end

        otu_table = joinpath(swarm_dir, "otu_table.csv")
        CSV.write(otu_table, df)
        @info "SWARM: $(length(otu_ids)) OTUs written to $otu_table (aggregated from ASV counts)"
        return otu_table
    end

    """
        swarm(project, asvs; swarm_bin, vsearch_bin) -> Union{OTUResult, Nothing}

    Run the SWARM OTU clustering pipeline on DADA2-denoised ASVs:
      annotate with abundances -> filter Ns -> cluster -> aggregate count table.

    DADA2 has already performed quality filtering, denoising, and chimera removal,
    so SWARM only needs to cluster the clean ASVs into OTUs.

    Outputs are written to `{project.dir}/swarm/`. Returns an OTUResult pointing to
    `seeds.fasta` (OTU representatives) and `otu_table.csv` (per-sample counts).
    """
    function swarm(project::ProjectCtx, asvs::ASVResult;
                   swarm_bin   = tool_bin("swarm"),
                   vsearch_bin = tool_bin("vsearch"))
        lbl = basename(project.dir)
        if isnothing(Sys.which(swarm_bin))
            @warn "[$lbl] SWARM: Binary not found ('$swarm_bin') - skipping OTU pipeline. Install swarm or set path in config/tools.yml."
            return nothing
        end
        config_path = write_run_config(project)
        cfg         = get(YAML.load_file(config_path), "swarm", Dict())
        swarm_dir   = joinpath(project.dir, "swarm")
        log_dir     = joinpath(swarm_dir, "logs")
        hash_file   = joinpath(swarm_dir, "config.hash")
        seeds       = joinpath(swarm_dir, "seeds.fasta")
        otu_table   = joinpath(swarm_dir, "otu_table.csv")
        membership  = joinpath(swarm_dir, "cluster_membership.csv")

        asv_mtime = mtime(asvs.fasta)
        if isfile(seeds) && isfile(otu_table) && isfile(membership) &&
           !_section_stale(config_path, stage_sections(:swarm), hash_file) &&
           mtime(seeds) > asv_mtime && mtime(otu_table) > asv_mtime
            @info "[$lbl] SWARM: Skipping - outputs up to date in $swarm_dir"
            return OTUResult(seeds, otu_table)
        end

        mkpath(swarm_dir); mkpath(log_dir)
        # Each command below appends to its own log, so the stage clears all three
        # once here; otherwise a re-run would accrete onto the previous run's record.
        reset_tool_logs(joinpath(log_dir, "filter_ns.log"),
                        joinpath(log_dir, "swarm.log"),
                        joinpath(log_dir, "rename.log"))

        args = _swarm_args(cfg)

        @info "[$lbl] SWARM: Annotating $(asvs.fasta) with abundances"
        annotated = _write_annotated_fasta(asvs, swarm_dir)

        @info "[$lbl] SWARM: Removing ambiguous-base sequences"
        cluster_input = _filter_ns!(annotated, swarm_dir, vsearch_bin, log_dir)

        @info "[$lbl] SWARM: Clustering"
        seeds = _cluster!(cluster_input, swarm_dir, args, swarm_bin, log_dir)

        @info "[$lbl] SWARM: Building OTU count table from ASV counts"
        otu_table = _build_count_table_from_asvs!(swarm_dir, seeds, asvs)

        _write_section_hash(config_path, stage_sections(:swarm), hash_file)
        pipeline_log(project, "SWARM complete")
        log_written(project, seeds)
        log_written(project, otu_table)
        return OTUResult(seeds, otu_table)
    end

end # module OTUPipeline
