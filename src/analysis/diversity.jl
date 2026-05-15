module DiversityMetrics

# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

import Random

export richness, shannon, simpson, rarefy, normalise_counts,
       auto_min_depth, NORMALISATION_METHODS

## Supported count depth-normalisation methods
const NORMALISATION_METHODS = ("none", "rarefy")

    """
        richness(counts) -> Int

    Observed richness: the number of non-zero features in `counts`.
    """
    richness(counts) = count(!iszero, counts)

    """
        shannon(counts) -> Float64

    Shannon diversity index H = -sum(p_i * ln(p_i)), where p_i is the
    relative abundance of feature i.  Zero-count features are ignored.
    Returns 0.0 when `counts` sums to zero.
    """
    function shannon(counts)
        n = sum(counts)
        n == 0 && return 0.0
        p = counts[counts .> 0] ./ n
        return -sum(p .* log.(p))
    end

    """
        simpson(counts) -> Float64

    Gini-Simpson diversity index 1 - sum(p_i^2), where p_i is the relative
    abundance of feature i.  Returns 0.0 when `counts` sums to zero.
    """
    function simpson(counts)
        n = sum(counts)
        n == 0 && return 0.0
        p = counts[counts .> 0] ./ n
        return 1.0 - sum(p .^ 2)
    end

    """
        rarefy(mat; depth, seed) -> Matrix{Float64}

    Subsample each sample row to exactly `depth` reads without replacement.
    Fractional input counts are rounded to the nearest integer before subsampling.
    """
    function rarefy(mat::Matrix{<:Real}; depth::Int, seed::Int)::Matrix{Float64}
        rng = Random.MersenneTwister(seed)
        nrows, nfeat = size(mat)
        out = zeros(Float64, nrows, nfeat)
        # One buffer reused across rows; grows to the largest library only.
        pool = Int[]
        for i in 1:nrows
            total = 0
            for j in 1:nfeat
                total += round(Int, mat[i, j])
            end
            resize!(pool, total)
            idx = 1
            for j in 1:nfeat
                for _ in 1:round(Int, mat[i, j])
                    pool[idx] = j
                    idx += 1
                end
            end
            # Partial Fisher-Yates: draw exactly `depth` reads without
            # replacement, tallying each as it is selected. Equivalent in
            # distribution to a full shuffle then taking the first `depth`,
            # but O(depth) rather than O(library size) random work.
            for k in 1:depth
                s = rand(rng, k:total)
                pool[k], pool[s] = pool[s], pool[k]
                out[i, pool[k]] += 1.0
            end
        end
        out
    end

    """
        auto_min_depth(lib_sizes) -> Int

    Auto rarefaction depth: the minimum strictly-positive library size across
    `lib_sizes`, or 0 when no sample has any reads.
    """
    function auto_min_depth(lib_sizes)
        best = nothing
        for s in lib_sizes
            s > 0 || continue
            (best === nothing || s < best) && (best = s)
        end
        best === nothing ? 0 : Int(best)
    end

    """
        normalise_counts(mat; method, depth, seed)
            -> (; mat::Matrix{Float64}, kept::Vector{Int})

    Dispatcher for count depth-normalisation. `method` is one of `"none"` or `"rarefy"`.

    `depth = 0` selects auto mode: the resolved depth is the minimum library
    size across samples that have at least one read.  Samples whose library
    size is strictly below the resolved depth are dropped before normalisation.

    Returns a named tuple `(; mat, kept)` where `kept` is the 1-based vector
    of retained row indices.  Callers must re-index any parallel label vectors
    (sample names, group labels, etc.) using `kept`.
    """
    function normalise_counts(mat::Matrix{<:Real};
                              method::String,
                              depth::Int,
                              seed::Int)::NamedTuple{(:mat, :kept), Tuple{Matrix{Float64}, Vector{Int}}}
        method in NORMALISATION_METHODS || error(
            "Unknown normalisation method: $method " *
            "(expected one of $(join(NORMALISATION_METHODS, ", ")))")
        if method == "none"
            return (; mat=Matrix{Float64}(mat), kept=collect(1:size(mat, 1)))
        end

        lib_sizes = vec(sum(mat; dims=2))
        resolved_depth = depth == 0 ? auto_min_depth(lib_sizes) : depth

        @info "Normalisation: method=$method, resolved depth=$resolved_depth ($(length(lib_sizes)) samples, lib sizes $(Int.(extrema(lib_sizes))))"
        kept = findall(>=(resolved_depth), lib_sizes)
        dropped = size(mat, 1) - length(kept)
        dropped > 0 && @info "Normalisation: dropped $dropped samples below depth $resolved_depth"

        sub = mat[kept, :]
        (; mat=rarefy(sub; depth=resolved_depth, seed), kept)
    end

end
