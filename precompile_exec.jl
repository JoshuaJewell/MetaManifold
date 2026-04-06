# Precompile execution script for PackageCompiler sysimage build.
#
# Exercises MetaManifold code paths so all method specializations are
# traced and compiled to native code. Only covers the MetaManifold package
# (core, pipeline, analysis) - NOT the Server module, which is loaded at
# runtime via include().

using MetaManifold
using MetaManifold.PipelineTypes, MetaManifold.PipelineLog, MetaManifold.Config
using MetaManifold.Databases, MetaManifold.DuckDBStore, MetaManifold.Validation
using MetaManifold.Tools, MetaManifold.TaxonomyTableTools, MetaManifold.ProjectSetup
using MetaManifold.DiversityMetrics, MetaManifold.Analysis

using CSV, DataFrames, DuckDB, DBInterface, JSON3, YAML, Logging

global_logger(NullLogger())

# Config resolution
let
    tmp = mktempdir()
    config_dir = joinpath(tmp, "config")
    defaults_dir = joinpath(config_dir, "defaults")
    mkpath(defaults_dir)

    open(joinpath(defaults_dir, "pipeline.yml"), "w") do io
        YAML.write(io, Dict("dada2" => Dict("filter_trim" => Dict("min_len" => 175))))
    end
    open(joinpath(config_dir, "pipeline.yml"), "w") do io
        YAML.write(io, Dict("vsearch" => Dict("enabled" => true)))
    end

    # write_run_config, _section_stale, _write_section_hash
    data_dir = joinpath(tmp, "data", "study", "run")
    mkpath(data_dir)
    touch(joinpath(data_dir, "sample_R1.fastq.gz"))
    touch(joinpath(data_dir, "sample_R2.fastq.gz"))

    proj_dir = joinpath(tmp, "projects", "study", "run")
    mkpath(proj_dir)

    ctx = ProjectCtx(proj_dir, config_dir, data_dir,
                     joinpath(tmp, "projects", "study"),
                     joinpath(tmp, "data", "study"),
                     [data_dir])
    try write_run_config(ctx) catch end

    rm(tmp; recursive=true, force=true)
end

# Project setup
let
    tmp = mktempdir()
    mkpath(joinpath(tmp, "data", "TestStudy", "run1"))
    touch(joinpath(tmp, "data", "TestStudy", "run1", "s_R1.fastq.gz"))
    touch(joinpath(tmp, "data", "TestStudy", "run1", "s_R2.fastq.gz"))
    mkpath(joinpath(tmp, "config", "defaults"))
    open(joinpath(tmp, "config", "defaults", "pipeline.yml"), "w") do io
        YAML.write(io, Dict("dada2" => Dict()))
    end
    open(joinpath(tmp, "config", "pipeline.yml"), "w") do io
        YAML.write(io, Dict())
    end
    try
        new_project("TestStudy";
                    data_dir=joinpath(tmp, "data"),
                    projects_dir=joinpath(tmp, "projects"),
                    config_dir=joinpath(tmp, "config"))
    catch end
    rm(tmp; recursive=true, force=true)
end

# DuckDB store
let
    tmp = mktempdir()
    merge_dir = joinpath(tmp, "merged")
    mkpath(merge_dir)
    CSV.write(joinpath(merge_dir, "merged.csv"),
              DataFrame(SeqName=["ASV1","ASV2"], sample1=[10,20], sample2=[30,40]))

    try load_results_db(merge_dir) catch end
    try
        with_results_db(merge_dir) do con
            df = DataFrame(DBInterface.execute(con, "SELECT * FROM merged"))
        end
    catch end
    rm(tmp; recursive=true, force=true)
end

# Diversity metrics
let
    counts = [10, 20, 30, 0, 5]
    richness(counts)
    shannon(counts)
    simpson(counts)
end

# Analysis (Plotly JSON builders)
let
    try
        alpha_chart(["s1","s2"], [10,20], [1.5,2.0], [0.8,0.9])
    catch end
    try
        taxa_bar_chart(["Taxon1","Taxon2"], ["s1","s2"], [10 20; 30 40])
    catch end
    try
        stats_df = DataFrame(sample=["s1","s2"], input=[100,200], filtered=[90,180])
        pipeline_stats_chart(stats_df)
    catch end
end

# Merge taxa (CSV/DataFrame heavy paths)
let
    tmp = mktempdir()
    proj_dir = joinpath(tmp, "proj")
    config_dir = joinpath(tmp, "config")
    data_dir = joinpath(tmp, "data")
    mkpath(proj_dir); mkpath(config_dir); mkpath(data_dir)

    ctx = ProjectCtx(proj_dir, config_dir, data_dir, proj_dir, data_dir, [data_dir])

    # Create minimal ASV files
    fasta = joinpath(proj_dir, "asvs.fasta")
    open(fasta, "w") do io
        println(io, ">ASV1\nACGT\n>ASV2\nTGCA")
    end
    seqtab = joinpath(proj_dir, "seqtab.csv")
    CSV.write(seqtab, DataFrame(SeqName=["ASV1","ASV2"], s1=[10,20]))
    tax = joinpath(proj_dir, "taxonomy.csv")
    CSV.write(tax, DataFrame(SeqName=["ASV1","ASV2"],
                             Kingdom=["k1","k2"], Phylum=["p1","p2"],
                             Class=["c1","c2"], Order=["o1","o2"],
                             Family=["f1","f2"], Genus=["g1","g2"],
                             Species=["sp1","sp2"]))
    asvs = ASVResult(fasta, seqtab, tax)

    open(joinpath(config_dir, "databases.yml"), "w") do io
        YAML.write(io, Dict("databases" => Dict("test" => Dict("label" => "Test"))))
    end
    try
        db_meta = make_db_meta(joinpath(config_dir, "databases.yml"), "test")
        merge_taxa_dada2_only(ctx, asvs, db_meta)
    catch end

    rm(tmp; recursive=true, force=true)
end

# Validation
let
    tmp = mktempdir()
    try validate_environment(joinpath(tmp, "tools.yml")) catch end
    rm(tmp; recursive=true, force=true)
end

@info "Precompile execution complete"
