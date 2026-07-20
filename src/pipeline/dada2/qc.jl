# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Web UI: QC page
# Stages: prefilter_qc, filter_trim

    ## Pre-filter quality assessment
    """
        prefilter_qc(config_path; progress)

    **Stage 1** - Plot unfiltered quality profiles.

    Review `Figures/quality_unfiltered.pdf` to choose `truncLen` and `maxEE`
    values in config before running `filter_trim()`.
    """
    function prefilter_qc(config_path::String; progress=nothing, input_dir=nothing, workspace_root=nothing)
        ctx  = _pipeline_context(config_path; input_dir, workspace_root)
        lbl  = ctx.run_label
        emit = _emitter(progress, lbl)
        @info "[$(lbl)] DADA2: Prefilter QC starting"

        unfiltered_pdf = joinpath(ctx.dirs["Figures"], "quality_unfiltered.pdf")
        hash_file      = joinpath(ctx.dirs["Checkpoints"], "prefilter_qc.hash")
        if isfile(unfiltered_pdf) &&
           !_section_stale(config_path, "dada2.file_patterns", hash_file)
            all_inputs = vcat(ctx.fwd_files, ctx.rev_files)
            if isempty(all_inputs) || all(mtime(unfiltered_pdf) > mtime(f) for f in all_inputs)
                @info "[$(lbl)] DADA2: Skipping prefilter QC - quality_unfiltered.pdf up to date"
                return nothing
            end
        end

        R"rm(list=ls())"
        _source_r_functions(ctx)
        log_path = joinpath(ctx.dirs["Logs"], "prefilter_qc.log")
        open(log_path, "w") do io; println(io, "=== prefilter_qc ===\nconfig: $config_path") end
        R"con <- file($log_path, open='at'); sink(con); sink(con, type='message')"
        try
            emit("Plotting unfiltered quality profiles")
            fwd_for_plot   = isempty(ctx.fwd_files) ? nothing : ctx.single_sample ? ctx.fwd_files[1:1] : ctx.fwd_files
            rev_for_plot   = isempty(ctx.rev_files) ? nothing : ctx.single_sample ? ctx.rev_files[1:1] : ctx.rev_files
            unfiltered_pdf = joinpath(ctx.dirs["Figures"], "quality_unfiltered.pdf")
            R"plot_quality_profiles($fwd_for_plot, $rev_for_plot, $unfiltered_pdf)"

        finally
            R"tryCatch({ sink(type='message'); sink(); close(con) }, error = function(e) NULL)"
        end
        _write_section_hash(config_path, "dada2.file_patterns", hash_file)
        emit("Written: $(joinpath(ctx.dirs["Figures"], "quality_unfiltered.pdf"))")
        emit("Log: $log_path")
        nothing
    end

    ## Filter and trim
    """
        filter_trim(config_path; progress)

    **Stage 2** - Filter and trim reads; plot filtered quality profiles.

    Review `Figures/quality_filtered.pdf`. If filtering looks appropriate,
    proceed to `learn_errors()`; otherwise adjust `truncLen` / `maxEE` in
    config and re-run this stage.

    Saves: `Checkpoints/ckpt_filter.RData`
    """
    function filter_trim(config_path::String; progress=nothing, input_dir=nothing, workspace_root=nothing)
        ctx     = _pipeline_context(config_path; input_dir, workspace_root)
        lbl     = ctx.run_label
        emit    = _emitter(progress, lbl)
        @info "[$(lbl)] DADA2: Filter and trim starting"

        filter_ckpt = ctx.ckpts["filter"]
        hash_file   = joinpath(ctx.dirs["Checkpoints"], "filter_trim.hash")
        if isfile(filter_ckpt) && !_section_stale(config_path, stage_sections(:dada2_filter_trim), hash_file)
            all_inputs = vcat(ctx.fwd_files, ctx.rev_files)
            if isempty(all_inputs) || all(mtime(filter_ckpt) > mtime(f) for f in all_inputs)
                @info "[$(lbl)] DADA2: Skipping filter and trim - checkpoint up to date"
                return nothing
            end
        end

        R"rm(list=ls())"
        _source_r_functions(ctx)
        ft      = ctx.cfg["filter_trim"]
        trunc_len = ft["trunc_len"]
        max_ee    = ft["max_ee"]
        verbose   = ctx.verbose
        in_fwd    = ctx.in_fwd
        out_fwd   = ctx.out_fwd
        in_rev    = ctx.in_rev_arg
        out_rev   = ctx.out_rev_arg
        fwd_out   = ctx.fwd_out
        rev_out   = ctx.rev_out

        log_path = joinpath(ctx.dirs["Logs"], "filter_trim.log")
        open(log_path, "w") do io; println(io, "=== filter_trim ===\nconfig: $config_path") end
        R"con <- file($log_path, open='at'); sink(con); sink(con, type='message')"
        try
            emit("Filtering and trimming reads")
            # Bind the read-path vectors to R names so the logged command reads
            # filterAndTrim(mm_in_fwd, ...) rather than dumping every path inline.
            R"mm_in_fwd  <- $in_fwd"
            R"mm_out_fwd <- $out_fwd"
            if ctx.mode == "paired"
                R"mm_in_rev  <- $in_rev"
                R"mm_out_rev <- $out_rev"
                _r_run_logged(
                    "filter_stats <- filterAndTrim(mm_in_fwd, mm_out_fwd, mm_in_rev, mm_out_rev" *
                    ", truncQ=$(_r_lit(ft["trunc_q"]))" *
                    ", truncLen=$(_r_lit(trunc_len))" *
                    ", maxEE=$(_r_lit(max_ee))" *
                    ", minLen=$(_r_lit(ft["min_len"]))" *
                    ", maxN=0, matchIDs=$(_r_lit(ft["match_ids"]))" *
                    ", rm.phix=$(_r_lit(ft["rm_phix"]))" *
                    ", verbose=$(_r_lit(verbose)))")
            else
                _r_run_logged(
                    "filter_stats <- filterAndTrim(mm_in_fwd, mm_out_fwd" *
                    ", truncQ=$(_r_lit(ft["trunc_q"]))" *
                    ", truncLen=$(_r_lit(trunc_len[1]))" *
                    ", maxEE=$(_r_lit(max_ee[1]))" *
                    ", minLen=$(_r_lit(ft["min_len"]))" *
                    ", maxN=0, rm.phix=$(_r_lit(ft["rm_phix"]))" *
                    ", verbose=$(_r_lit(verbose)))")
            end

            emit("Plotting filtered quality profiles")
            fwd_filt = isempty(fwd_out) ? nothing : ctx.single_sample ? fwd_out[1:1] : fwd_out
            rev_filt = isempty(rev_out) ? nothing : ctx.single_sample ? rev_out[1:1] : rev_out
            filtered_pdf = joinpath(ctx.dirs["Figures"], "quality_filtered.pdf")
            R"plot_quality_profiles($fwd_filt, $rev_filt, $filtered_pdf)"

            ckpt = ctx.ckpts["filter"]
            R"save(filter_stats, file=$ckpt)"
        finally
            R"tryCatch({ sink(type='message'); sink(); close(con) }, error = function(e) NULL)"
        end
        _write_section_hash(config_path, stage_sections(:dada2_filter_trim), hash_file)
        emit("Written: $(joinpath(ctx.dirs["Figures"], "quality_filtered.pdf"))")
        emit("Checkpoint: $(ctx.ckpts["filter"])")
        emit("Log: $log_path")
        nothing
    end
