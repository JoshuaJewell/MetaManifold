module DADA2

# DADA2 amplicon sequencing pipeline - Julia orchestrator
#
# Stages and their Web UI page groupings:
#
#   QC page:        prefilter_qc, filter_trim
#   Denoising page: learn_errors, denoise, filter_length, chimera_removal
#   Taxonomy page:  assign_taxonomy
#
# Each stage is independently callable and saves a checkpoint so the pipeline
# can be resumed or individual stages re-run across Julia sessions.
#
# Call dada2() to run all stages in sequence without stopping.
#
# Notice:
#
# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).
#
# This work is based on the DADA2 tutorial by Benjamin J. Callahan, et al.,
# available at https://benjjneb.github.io/dada2/tutorial.html, with modification
# into a single module. The original material is licensed under the Creative
# Commons Attribution 4.0 International License (CC BY 4.0):
# https://creativecommons.org/licenses/by/4.0/.

export dada2, dada2_denoise, dada2_classify,
       prefilter_qc, filter_trim, learn_errors, denoise,
       filter_length, chimera_removal, assign_taxonomy

    import Downloads
    using Logging, RCall, YAML
    using ..PipelineTypes
    using ..PipelineLog
    using ..Databases
    using ..Config
    using ..Validation

    include("dada2/context.jl")   # shared helpers and _pipeline_context
    include("dada2/qc.jl")        # prefilter_qc, filter_trim
    include("dada2/denoise.jl")   # learn_errors, denoise, filter_length
    include("dada2/chimera.jl")   # chimera_removal
    include("dada2/taxonomy.jl")  # assign_taxonomy

    """
        dada2(config_path; progress)

    Run the complete DADA2 pipeline from raw reads to a taxonomy-annotated ASV
    table, calling all stages in sequence:

        prefilter_qc -> filter_trim -> learn_errors ->
        denoise -> filter_length -> chimera_removal -> assign_taxonomy

    For interactive use - reviewing intermediate outputs or adjusting parameters
    between steps - call the individual stage functions directly instead.

    ## Outputs
    Written to `workspace.root/Tables/`:
    - `seqtab_nochim.csv`              - chimera-free ASV count table
    - `asvs.fasta` / `asvs.csv`       - ASV sequences with short identifiers
    - `taxonomy.csv`                   - taxonomy assignments
    - `taxonomy_bootstraps.csv`        - bootstrap confidence values
    - `taxonomy_combined.csv`          - taxonomy + bootstraps combined
    - `tax_counts.csv`                 - taxonomy + per-sample counts
    - `asv_counts.csv`                 - ASV sequences + per-sample counts (no taxonomy)
    - `pipeline_stats.csv`             - read counts at each pipeline stage

    Written to `workspace.root/Checkpoints/`:
    - `ckpt_filter.RData`  - filter_stats
    - `ckpt_errors.RData`  - fwd_errors, rev_errors
    - `ckpt_denoise.RData` - dada objects, merged, unfiltered seq_table
    - `ckpt_length.RData`  - dada objects, merged, length-filtered seq_table
    - `ckpt_chimera.RData` - seq_table_nochim, index
    - `checkpoint.RData`   - final R environment snapshot
    """
    function dada2(config_path::String; progress=nothing, input_dir=nothing, workspace_root=nothing, taxonomy_db=nothing)
        _single_sample_warned[] = false
        R"rm(list=ls())"
        prefilter_qc(config_path; progress, input_dir, workspace_root)
        filter_trim(config_path; progress, input_dir, workspace_root); R"gc()"
        learn_errors(config_path; progress, input_dir, workspace_root); R"gc()"
        denoise(config_path; progress, input_dir, workspace_root); R"gc()"
        filter_length(config_path; progress, input_dir, workspace_root); R"gc()"
        chimera_removal(config_path; progress, input_dir, workspace_root); R"gc()"
        assign_taxonomy(config_path; progress, input_dir, workspace_root, taxonomy_db)
    end

    """
        dada2_denoise(project, trimmed; progress) -> DenoisedASVs

    Run all DADA2 stages up to and including chimera removal. Returns a
    `DenoisedASVs` wire type that can be passed to `dada2_classify()`.

    Skips automatically if `ckpt_chimera.RData` is newer than both `dada2.yml`
    and the trimmed reads. Individual stage skip guards apply for partial runs.
    """
    function dada2_denoise(project::ProjectCtx, trimmed::TrimmedReads; progress=nothing)
        config_path    = write_run_config(project)
        workspace_root = joinpath(project.dir, "dada2")
        chimera_ckpt   = joinpath(workspace_root, "Checkpoints", "ckpt_chimera.RData")

        trimmed_files = filter(f -> endswith(f, "_trimmed.fastq.gz"), readdir(trimmed.dir))
        trimmed_mtime = isempty(trimmed_files) ? 0.0 :
                        maximum(mtime(joinpath(trimmed.dir, f)) for f in trimmed_files)

        ckpt_dir = joinpath(workspace_root, "Checkpoints")
        if isfile(chimera_ckpt) &&
           mtime(chimera_ckpt) > trimmed_mtime &&
           !_section_stale(config_path, stage_sections(:dada2_filter_trim), joinpath(ckpt_dir, "filter_trim.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_learn_errors), joinpath(ckpt_dir, "learn_errors.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_denoise), joinpath(ckpt_dir, "denoise.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_filter_length), joinpath(ckpt_dir, "filter_length.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_chimera_removal), joinpath(ckpt_dir, "chimera_removal.hash"))
            @info "[$(basename(dirname(workspace_root)))] DADA2: Skipping denoise - ckpt_chimera.RData up to date"
        else
            R"rm(list=ls())"
            prefilter_qc(config_path;    progress, input_dir=trimmed.dir, workspace_root)
            filter_trim(config_path;     progress, input_dir=trimmed.dir, workspace_root); R"gc()"
            learn_errors(config_path;    progress, input_dir=trimmed.dir, workspace_root); R"gc()"
            denoise(config_path;         progress, input_dir=trimmed.dir, workspace_root); R"gc()"
            filter_length(config_path;   progress, input_dir=trimmed.dir, workspace_root); R"gc()"
            chimera_removal(config_path; progress, input_dir=trimmed.dir, workspace_root); R"gc()"
            pipeline_log(project, "DADA2 denoising complete")
        end

        return DenoisedASVs(chimera_ckpt, config_path, workspace_root, trimmed.dir)
    end

    """
        dada2_classify(project, denoised; taxonomy_db, progress) -> ASVResult

    Run taxonomy assignment on a `DenoisedASVs` result and return an `ASVResult`.
    Respects the mtime skip guard inside `assign_taxonomy()`.
    """
    function dada2_classify(project::ProjectCtx, denoised::DenoisedASVs;
                            taxonomy_db=nothing, progress=nothing, skip_taxonomy=false)
        config_path    = denoised.config_path
        workspace_root = denoised.workspace_root
        cfg        = get(YAML.load_file(config_path), "dada2", Dict())
        out_cfg    = get(cfg, "output", Dict())
        tables_dir = joinpath(workspace_root, "Tables")
        result = ASVResult(
            joinpath(tables_dir, get(out_cfg, "fasta_prefix",     "asvs")          * ".fasta"),
            joinpath(tables_dir, get(out_cfg, "seq_table_prefix", "seqtab_nochim") * ".csv"),
            joinpath(tables_dir, get(out_cfg, "taxa_prefix",      "taxonomy")      * ".csv")
        )
        assign_taxonomy(config_path;
                        progress,
                        input_dir      = denoised.input_dir,
                        workspace_root,
                        taxonomy_db,
                        skip_classification = skip_taxonomy)
        pipeline_log(project, "DADA2 taxonomy complete")
        R"rm(list=ls()); gc()"
        for f in (result.fasta, result.count_table, result.taxonomy)
            isfile(f) && log_written(project, f)
        end
        return result
    end

    function dada2(project::ProjectCtx, trimmed::TrimmedReads;
                   taxonomy_db=nothing, progress=nothing, skip_taxonomy=false)
        config_path    = write_run_config(project)
        workspace_root = joinpath(project.dir, "dada2")
        cfg        = get(YAML.load_file(config_path), "dada2", Dict())
        out_cfg    = get(cfg, "output", Dict())
        tables_dir = joinpath(workspace_root, "Tables")
        result = ASVResult(
            joinpath(tables_dir, get(out_cfg, "fasta_prefix",     "asvs")          * ".fasta"),
            joinpath(tables_dir, get(out_cfg, "seq_table_prefix", "seqtab_nochim") * ".csv"),
            joinpath(tables_dir, get(out_cfg, "taxa_prefix",      "taxonomy")      * ".csv")
        )
        trimmed_files = filter(f -> endswith(f, "_trimmed.fastq.gz"), readdir(trimmed.dir))
        trimmed_mtime = isempty(trimmed_files) ? 0.0 :
                        maximum(mtime(joinpath(trimmed.dir, f)) for f in trimmed_files)
        ckpt_dir = joinpath(workspace_root, "Checkpoints")
        if all(isfile, (result.fasta, result.count_table, result.taxonomy)) &&
           all(f -> mtime(f) > trimmed_mtime, (result.fasta, result.count_table, result.taxonomy)) &&
           !_section_stale(config_path, stage_sections(:dada2_filter_trim), joinpath(ckpt_dir, "filter_trim.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_learn_errors), joinpath(ckpt_dir, "learn_errors.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_denoise), joinpath(ckpt_dir, "denoise.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_filter_length), joinpath(ckpt_dir, "filter_length.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_chimera_removal), joinpath(ckpt_dir, "chimera_removal.hash")) &&
           !_section_stale(config_path, stage_sections(:dada2_assign_taxonomy), joinpath(ckpt_dir, "assign_taxonomy.hash"))
            @info "[$(basename(project.dir))] DADA2: Skipping - outputs up to date in $tables_dir"
            return result
        end
        @info "[$(basename(project.dir))] DADA2: Starting pipeline"
        pipeline_log(project, "DADA2 pipeline started")
        denoised = dada2_denoise(project, trimmed; progress)
        result = dada2_classify(project, denoised; taxonomy_db, progress, skip_taxonomy)
        pipeline_log(project, "DADA2 complete")
        return result
    end

end
