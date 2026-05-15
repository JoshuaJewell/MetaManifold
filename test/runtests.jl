#!/usr/bin/env julia
# MetabarcodingPipeline test suite
#
# Run with:
#   julia --project=. test/runtests.jl
#
# For integration tests (requires tools + databases):
#   julia --project=. -t4 test/runtests.jl --integration
using Test

const RUN_INTEGRATION = "--integration" in ARGS
const RUN_SERVER      = "--server"      in ARGS

using MetaManifold
using CSV, DataFrames, JSON3, Logging, YAML, DuckDB, DBInterface, Dates

using MetaManifold.PipelineTypes, MetaManifold.PipelineLog, MetaManifold.Config
using MetaManifold.Databases, MetaManifold.DuckDBStore, MetaManifold.Validation
using MetaManifold.Tools, MetaManifold.TaxonomyTableTools, MetaManifold.ProjectSetup
using MetaManifold.DiversityMetrics, MetaManifold.Analysis
using MetaManifold.FuncDBAnnotation

## Unit tests (always run)
@testset "MetabarcodingPipeline" begin

    include("unit/test_diversity.jl")
    include("unit/test_merge_taxa.jl")
    include("unit/test_config.jl")
    include("unit/test_validation.jl")
    include("unit/test_tools.jl")
    include("unit/test_analysis.jl")
    include("unit/test_duckdb_store.jl")
    include("unit/test_analysis_duckdb.jl")
    include("unit/test_config_hashing.jl")
    include("unit/test_project.jl")
    include("unit/test_log.jl")
    include("unit/test_databases.jl")
    include("unit/test_merge_taxa_mappings.jl")
    include("unit/test_funcdb.jl")

    ## Integration tests (opt-in)
    if RUN_INTEGRATION
        using MetaManifold.DADA2, MetaManifold.OTUPipeline
        include("integration/test_pipeline.jl")
    else
        @info "Skipping integration tests (pass --integration to enable)"
    end

    ## Server smoke tests (opt-in, starts a Julia subprocess - slow on first run)
    if RUN_SERVER
        using HTTP
        include("integration/test_server.jl")
    else
        @info "Skipping server smoke tests (pass --server to enable)"
    end

end
