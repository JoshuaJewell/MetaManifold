# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## R runtime
# RCall hosts exactly one embedded R session per Julia process, and R is neither
# thread-safe nor reentrant. Every caller that evaluates R must therefore
# serialise on the single lock defined here: the DADA2 pipeline stages, which run
# on spawned job threads, and the NMDS, PERMANOVA, and alpha-significance
# analyses, which run on HTTP handler tasks.
#
# Guarding one interpreter with two separate locks is not mutual exclusion, it is
# a data race. The pipeline resets the workspace with `rm(list=ls())` when it
# acquires the runtime, so it will destroy the globals an analysis is midway
# through evaluating; and a single user is enough to provoke it, since a pipeline
# runs on a background thread while the browser stays live.
module RRuntime

export RBusyError, with_r_lock, r_busy

const _R_LOCK = ReentrantLock()

# Thrown when a caller that declines to wait indefinitely gives up on the runtime.
struct RBusyError <: Exception
    waited :: Float64
end

Base.showerror(io::IO, e::RBusyError) = print(io,
    "R runtime busy: another task, typically a pipeline run, held it for " *
    "longer than $(e.waited)s")

# True while any task holds the R runtime.
r_busy() = islocked(_R_LOCK)

"""
    with_r_lock(f; timeout=nothing) -> f()

Run `f` with exclusive access to the embedded R runtime.

With no `timeout` the caller waits for as long as it takes. That is what a
pipeline stage wants: it is the work the user explicitly asked for, and dropping
it because an analysis happened to be running would be worse than waiting.

With a `timeout` in seconds the caller waits at most that long and then throws
`RBusyError`. Interactive request handlers pass one, so that a pipeline run,
which can hold the runtime for hours, cannot hang an HTTP response indefinitely.
"""
function with_r_lock(f::Function; timeout::Union{Real,Nothing}=nothing)
    isnothing(timeout) && return lock(f, _R_LOCK)
    deadline = time() + timeout
    while true
        if trylock(_R_LOCK)
            try
                return f()
            finally
                unlock(_R_LOCK)
            end
        end
        time() >= deadline && throw(RBusyError(Float64(timeout)))
        sleep(0.05)
    end
end

end # module RRuntime
