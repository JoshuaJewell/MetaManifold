# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

    ## Taxonomy Assignment
    """
        assign_taxonomy(config_path; progress)

    **Stage 7** - Assign taxonomy to ASVs and write the combined output table.

    Requires: `Checkpoints/ckpt_chimera.RData`
    Saves: `Checkpoints/checkpoint.RData`
    """
    function _assign_taxonomy_remote(emit, chimera_ckpt, db_path, db_remote_path, tables_dir,
                                      checkpoint, taxa_prefix, multithread,
                                      min_boot, tax_levels, verbose, remote_cfg,
                                      log_path)
        host          = remote_cfg["host"]
        rscript       = get(remote_cfg, "rscript", "Rscript")
        base_dir      = get(remote_cfg, "staging_dir", nothing)
        identity_file = get(remote_cfg, "identity_file", nothing)

        isnothing(base_dir) &&
            error("taxonomy.remote.staging_dir must be set explicitly in config")
        !isnothing(db_remote_path) && !startswith(string(db_remote_path), "/") &&
            error("databases.yml dada2.remote_path must be an absolute path on the server " *
                  "(got: '$db_remote_path'). Do not include the hostname.")

        run_id      = string(floor(Int, time()))
        staging_dir = "$base_dir/run_$run_id"

        scripts_dir   = @__DIR__
        functions_r   = joinpath(scripts_dir, "dada2_functions.r")
        remote_r      = joinpath(scripts_dir, "taxonomy_remote.r")
        remote_tables = "$staging_dir/Tables"
        remote_ckpt   = "$staging_dir/checkpoint.RData"

        # ControlMaster reuses a single SSH connection for all ssh/scp calls
        ctl     = "/tmp/ssh_mux_$run_id"
        id_opt  = isnothing(identity_file) ? `` : `-i $identity_file`
        ssh_opts = `$id_opt -o ControlMaster=auto -o ControlPath=$ctl -o ControlPersist=yes -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=3`
        ssh = (args...) -> `ssh $ssh_opts $args`
        scp = (args...) -> `scp $ssh_opts $args`

        if isnothing(identity_file)
            emit("  Connecting to $host (enter SSH password if prompted)...")
        else
            emit("  Connecting to $host (key: $identity_file)...")
        end
        emit("  Setting up staging directory on $host")
        run(ssh(host, "mkdir -p $remote_tables"))

        emit("  Transferring files to $host")
        run(scp(chimera_ckpt, "$host:$staging_dir/ckpt_chimera.RData"))
        run(scp(functions_r,  "$host:$staging_dir/dada2_functions.r"))
        run(scp(remote_r,     "$host:$staging_dir/taxonomy_remote.r"))

        # Use remote_path from databases.yml if set, otherwise transfer local db
        remote_db_resolved = if !isnothing(db_remote_path)
            emit("  Using remote database: $db_remote_path")
            db_remote_path
        elseif !isnothing(db_path)
            db_basename = basename(db_path)
            emit("  Transferring database ($db_basename) to $host")
            run(scp(db_path, "$host:$staging_dir/$db_basename"))
            "$staging_dir/$db_basename"
        else
            error("No taxonomy database: set databases.yml dada2.remote_path or provide a local database")
        end

        levels_str  = join(tax_levels, ",")
        verbose_str = verbose ? "true" : "false"
        mt_str      = multithread isa Bool ? (multithread ? "TRUE" : "FALSE") : string(multithread)
        remote_cmd  = "$rscript $staging_dir/taxonomy_remote.r " *
                      "functions=$staging_dir/dada2_functions.r " *
                      "ckpt=$staging_dir/ckpt_chimera.RData " *
                      "db=$remote_db_resolved " *
                      "tables=$remote_tables " *
                      "save=$remote_ckpt " *
                      "prefix=$taxa_prefix " *
                      "multithread=$mt_str " *
                      "min_boot=$min_boot " *
                      "levels=$levels_str " *
                      "verbose=$verbose_str"

        emit("  Running Rscript on $host:$staging_dir")
        open(log_path, "a") do io
            run(pipeline(ssh(host, remote_cmd); stdout=io, stderr=io))
        end

        emit("  Retrieving results from $host")
        run(scp("$host:$remote_tables/$taxa_prefix.csv",              "$tables_dir/"))
        run(scp("$host:$remote_tables/$(taxa_prefix)_bootstraps.csv", "$tables_dir/"))
        run(scp("$host:$remote_tables/$(taxa_prefix)_combined.csv",   "$tables_dir/"))
        run(scp("$host:$remote_ckpt",                                 checkpoint))

        # Guard against dangerously shallow rm -rf paths
        parts = filter(!isempty, split(staging_dir, '/'))
        if length(parts) >= 3
            emit("  Cleaning up $host:$staging_dir")
            run(ssh(host, "rm -rf $staging_dir"))
        else
            @warn "DADA2: Skipping remote cleanup - staging path '$staging_dir' looks too shallow to delete safely"
        end

        run(`ssh -o ControlPath=$ctl -O exit $host`)
    end

    function assign_taxonomy(config_path::String; progress=nothing, input_dir=nothing, workspace_root=nothing, taxonomy_db=nothing, skip_classification=false)
        ctx     = _pipeline_context(config_path; input_dir, workspace_root)
        lbl     = ctx.run_label
        emit    = _emitter(progress, lbl)
        @info "[$(lbl)] DADA2: Assign taxonomy starting"
        verbose = ctx.verbose

        isfile(ctx.ckpts["chimera"]) ||
            error("Chimera checkpoint not found. Run chimera_removal() first.")

        chimera_ckpt = ctx.ckpts["chimera"]
        checkpoint   = joinpath(ctx.dirs["Checkpoints"], "checkpoint.RData")
        hash_file    = joinpath(ctx.dirs["Checkpoints"], "assign_taxonomy.hash")
        if isfile(checkpoint) &&
           !_section_stale(config_path, stage_sections(:dada2_assign_taxonomy), hash_file) &&
           mtime(checkpoint) > mtime(chimera_ckpt)
            @info "[$(lbl)] DADA2: Skipping assign taxonomy - checkpoint up to date"
            return nothing
        end

        # Free R data objects from prior stages to reduce memory before taxonomy
        R"""
        .data_objs <- setdiff(ls(), lsf.str())
        if (length(.data_objs) > 0L) rm(list = .data_objs)
        rm(.data_objs)
        gc()
        """
        _source_r_functions(ctx)

        seq_prefix    = get(ctx.cfg["output"], "seq_table_prefix", "seqtab_nochim")
        fasta_prefix  = get(ctx.cfg["output"], "fasta_prefix", "asvs")
        taxa_prefix   = get(ctx.cfg["output"], "taxa_prefix", "taxonomy")
        combined_file = "tax_counts.csv"
        asv_file      = "asv_counts.csv"
        tables_dir    = ctx.dirs["Tables"]
        multithread   = get(ctx.cfg["taxonomy"], "multithread", 4)
        # Guard the Julia/R boundary: YAML ambiguity between `true`, `4`, and
        # `"4"` previously flipped the assignTaxonomy code path silently. Only
        # a Bool or a strict positive Integer is meaningful here.
        (multithread isa Bool) ||
            (multithread isa Integer && multithread >= 1) ||
            error("taxonomy.multithread must be a Bool or positive integer (got: $(repr(multithread)))")
        min_boot      = get(ctx.cfg["taxonomy"], "min_boot", 0)
        db_key    = string(ctx.cfg["taxonomy"]["database"])
        dbs_path  = joinpath(@__DIR__, "..", "..", "..", "config", "databases.yml")
        dbs_cfg   = get(YAML.load_file(dbs_path), "databases", Dict())
        tax_levels = String[string(l) for l in get(get(dbs_cfg, db_key, Dict()), "levels", String[])]
        isempty(tax_levels) && error("No levels defined for database '$db_key' in $dbs_path")

        remote_cfg = get(get(ctx.cfg, "taxonomy", Dict()), "remote", nothing)
        use_remote = !isnothing(remote_cfg) &&
                     !isnothing(get(remote_cfg, "host", nothing))

        # Priority: remote_path > taxonomy_db arg > _resolve_taxonomy_db fallback
        db_remote_path = get(get(get(dbs_cfg, db_key, Dict()), "dada2", Dict()), "remote_path", nothing)
        if !isnothing(db_remote_path)
            db_remote_path = string(db_remote_path)
        end
        db_path = isnothing(taxonomy_db) ? _resolve_taxonomy_db(ctx.cfg, emit) : taxonomy_db

        R"load($chimera_ckpt)"
        has_data = rcopy(R"isTRUE(sum(seq_table_nochim, na.rm=TRUE) > 0)")

        log_path = joinpath(ctx.dirs["Logs"], "assign_taxonomy.log")
        open(log_path, "w") do io; println(io, "=== assign_taxonomy ===\nconfig: $config_path") end

        if skip_classification
            @info "[$(lbl)] DADA2: Taxonomy classification skipped - writing count tables without assignments"
            R"""
            taxa_df <- data.frame(SeqName = index$SeqName, Sequence = index$Sequence,
                                  stringsAsFactors = FALSE)
            """
            R"write_combined_table(taxa_df, index, seq_table_nochim, $tables_dir, $combined_file, $asv_file)"
            R"save(seq_table_nochim, index, taxa_df, file=$checkpoint)"
            for suffix in (taxa_prefix * ".csv", taxa_prefix * "_bootstraps.csv",
                           taxa_prefix * "_combined.csv")
                touch(joinpath(tables_dir, suffix))
            end
        elseif !has_data
            @info "[$(lbl)] DADA2: Taxonomy assignment skipped - no ASVs in seq_table_nochim"
            R"taxa_df <- data.frame()"
            R"save(seq_table_nochim, index, taxa_df, file=$checkpoint)"
            for suffix in (taxa_prefix * ".csv", taxa_prefix * "_bootstraps.csv",
                           taxa_prefix * "_combined.csv", combined_file, asv_file)
                touch(joinpath(tables_dir, suffix))
            end
        elseif use_remote
            emit("Assigning taxonomy (remote: $(remote_cfg["host"]))")
            _assign_taxonomy_remote(emit, chimera_ckpt, db_path, db_remote_path, tables_dir,
                                    checkpoint, taxa_prefix, multithread,
                                    min_boot, tax_levels, verbose, remote_cfg,
                                    log_path)
            R"load($checkpoint)"
            R"write_combined_table(taxa_df, index, seq_table_nochim, $tables_dir, $combined_file, $asv_file)"
            emit("Log: $log_path")
        else
            R"con <- file($log_path, open='at'); sink(con); sink(con, type='message')"
            try
                emit("Assigning taxonomy")
                R"""
                taxa_result <- run_assign_taxonomy(
                    seq_table_nochim, $db_path,
                    list(multithread=$multithread, min_boot=$min_boot, levels=$tax_levels),
                    $verbose)
                taxa_df <- write_taxa_table(taxa_result$tax, taxa_result$boot, index,
                                            $tables_dir, $taxa_prefix)
                """
                R"gc()"
                R"save(seq_table_nochim, index, taxa_df, file=$checkpoint)"
            finally
                R"tryCatch({ sink(type='message'); sink(); close(con) }, error = function(e) NULL)"
            end
            R"write_combined_table(taxa_df, index, seq_table_nochim, $tables_dir, $combined_file, $asv_file)"
            emit("Log: $log_path")
        end

        _write_section_hash(config_path, stage_sections(:dada2_assign_taxonomy), hash_file)
        emit("Checkpoint: $checkpoint")

        emit("Pipeline complete. Outputs:")
        emit("  $(joinpath(tables_dir, seq_prefix * ".csv"))")
        emit("  $(joinpath(tables_dir, fasta_prefix * ".fasta"))")
        emit("  $(joinpath(tables_dir, fasta_prefix * ".csv"))")
        emit("  $(joinpath(tables_dir, taxa_prefix * ".csv"))")
        emit("  $(joinpath(tables_dir, taxa_prefix * "_bootstraps.csv"))")
        emit("  $(joinpath(tables_dir, taxa_prefix * "_combined.csv"))")
        emit("  $(joinpath(tables_dir, combined_file))")
        emit("  $(joinpath(tables_dir, asv_file))")
        emit("  $(joinpath(tables_dir, "pipeline_stats.csv"))")
        emit("  $checkpoint")
        nothing
    end
