module MetaManifold

# Core
include("core/types.jl")
include("core/r_runtime.jl")
# Provenance probes R through the shared runtime lock, so it follows r_runtime.jl.
include("core/provenance.jl")
include("core/log.jl")
include("core/config.jl")
include("core/databases.jl")
include("core/duckdb_store.jl")
include("core/validate.jl")
include("core/project.jl")
include("core/categories.jl")
include("core/composition_library.jl")
include("core/primers_library.jl")
include("core/databases_library.jl")

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
