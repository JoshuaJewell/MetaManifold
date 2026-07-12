module MetaManifold

# Core
include("core/types.jl")
include("core/log.jl")
include("core/config.jl")
include("core/databases.jl")
include("core/duckdb_store.jl")
include("core/validate.jl")
include("core/project.jl")
include("core/categories.jl")

# Annotation
include("annotation/funcdb.jl")

# Pipeline
include("pipeline/tools.jl")
include("pipeline/merge_taxa.jl")
include("pipeline/dada2.jl")
include("pipeline/swarm.jl")

# Analysis
include("analysis/diversity.jl")
include("analysis/analysis.jl")

end
