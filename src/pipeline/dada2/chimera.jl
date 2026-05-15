# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## Chimera Removal
    """
        chimera_removal(config_path; progress)

    **Stage 6** - Remove chimeric sequences, drop the single-sample duplicate
    row if present, and write core output files (seq table, FASTA, pipeline
    stats).

    Review `Tables/pipeline_stats.csv` for unexpected read loss before
    committing to the (potentially long) `assign_taxonomy()` step.

    The `asv.denovo_method` config key selects DADA2's chimera detection mode.
    Allowed values are `"consensus"`, `"pooled"`, and `"per-sample"`; any
    other value raises before R is invoked.

    Requires: `Checkpoints/ckpt_filter.RData`, `Checkpoints/ckpt_length.RData`
    Saves: `Checkpoints/ckpt_chimera.RData`
    """
    function chimera_removal(config_path::String; progress=nothing, input_dir=nothing, workspace_root=nothing)
        ctx     = _pipeline_context(config_path; input_dir, workspace_root)
        lbl     = ctx.run_label
        emit    = _emitter(progress, lbl)
        @info "[$(lbl)] DADA2: Chimera removal starting"
        verbose = ctx.verbose
        mode    = ctx.mode

        isfile(ctx.ckpts["filter"]) ||
            error("Filter checkpoint not found. Run filter_trim() first.")
        isfile(ctx.ckpts["length"]) ||
            error("Length filter checkpoint not found. Run filter_length() first.")
        filter_ckpt = ctx.ckpts["filter"]
        length_ckpt = ctx.ckpts["length"]

        chimera_ckpt = ctx.ckpts["chimera"]
        hash_file    = joinpath(ctx.dirs["Checkpoints"], "chimera_removal.hash")
        if isfile(chimera_ckpt) &&
           !_section_stale(config_path, stage_sections(:dada2_chimera_removal), hash_file) &&
           mtime(chimera_ckpt) > mtime(filter_ckpt) &&
           mtime(chimera_ckpt) > mtime(length_ckpt)
            @info "[$(lbl)] DADA2: Skipping chimera removal - checkpoint up to date"
            return nothing
        end

        R"rm(list=ls())"
        _source_r_functions(ctx)
        seq_prefix   = get(ctx.cfg["output"], "seq_table_prefix", "seqtab_nochim")
        fasta_prefix = get(ctx.cfg["output"], "fasta_prefix", "asvs")
        tables_dir   = ctx.dirs["Tables"]

        log_path = joinpath(ctx.dirs["Logs"], "chimera_removal.log")
        open(log_path, "w") do io; println(io, "=== chimera_removal ===\nconfig: $config_path") end
        R"con <- file($log_path, open='at'); sink(con); sink(con, type='message')"
        try
            R"load($filter_ckpt)"
            R"load($length_ckpt)"

            has_data = rcopy(R"isTRUE(sum(seq_table, na.rm=TRUE) > 0)")
            emit("Removing chimeras")
            if has_data
                denovo_method = ctx.cfg["asv"]["denovo_method"]
                # Guard at the Julia/R boundary: an unrecognised method silently
                # degrades downstream chimera calls and produces an opaque R
                # error rather than a clear Julia validation failure.
                denovo_method isa AbstractString && denovo_method in Validation.DENOVO_METHODS ||
                    error("asv.denovo_method must be one of $(join(Validation.DENOVO_METHODS, ", ")) " *
                          "(got: $(repr(denovo_method)))")
                R"""
                seq_table_nochim <- removeBimeraDenovo(seq_table, method=$denovo_method, verbose=$verbose)
                nochim_pct <- sum(seq_table_nochim) / sum(seq_table) * 100
                message("  Chimeric reads removed: ", round(100 - nochim_pct, 2),
                        "% | Retained: ", round(nochim_pct, 2), "%")
                """
            else
                R"seq_table_nochim <- seq_table"
                @info "[$(lbl)] DADA2: Chimera removal skipped - seq_table is empty"
            end

            # Single-sample mode produces a duplicate row - collapse it
            final_names = ctx.sample_names
            if ctx.single_sample
                R"filter_stats     <- filter_stats[1, , drop=FALSE]"
                mode != "reverse" && R"dada_fwd <- dada_fwd[1]"
                mode != "forward" && R"dada_rev <- dada_rev[1]"
                mode == "paired"  && R"merged   <- merged[1]"
                R"seq_table_nochim <- seq_table_nochim[1, , drop=FALSE]"
                final_names = [ctx.sample_names[1]]
            end

            emit("Computing pipeline stats")
            stats_csv = joinpath(ctx.dirs["Tables"], "pipeline_stats.csv")
            R"""
            stats <- compute_pipeline_stats(filter_stats, dada_fwd, dada_rev, merged,
                                            seq_table_nochim, $final_names, $mode)
            write.csv(stats, $stats_csv, quote=FALSE)
            if ($verbose) print(stats)
            """

            emit("Writing core output tables")
            if has_data
                R"write_seq_table(seq_table_nochim, $tables_dir, $seq_prefix)"
                R"index <- write_fasta(seq_table_nochim, $tables_dir, $fasta_prefix)"
            else
                R"index <- data.frame(SeqName=character(0), sequence=character(0))"
                touch(joinpath(tables_dir, seq_prefix   * ".csv"))
                touch(joinpath(tables_dir, fasta_prefix * ".fasta"))
                touch(joinpath(tables_dir, fasta_prefix * ".csv"))
            end

            ckpt = ctx.ckpts["chimera"]
            R"save(seq_table_nochim, index, file=$ckpt)"
        finally
            R"tryCatch({ sink(type='message'); sink(); close(con) }, error = function(e) NULL)"
        end
        _write_section_hash(config_path, stage_sections(:dada2_chimera_removal), hash_file)
        emit("Written: $(joinpath(tables_dir, "pipeline_stats.csv"))")
        emit("Written: $(joinpath(tables_dir, seq_prefix * ".csv"))")
        emit("Written: $(joinpath(tables_dir, fasta_prefix * ".fasta"))")
        emit("Checkpoint: $(ctx.ckpts["chimera"])")
        emit("Log: $log_path")
        nothing
    end
