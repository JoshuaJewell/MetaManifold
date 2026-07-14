# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## R runtime mutual exclusion
# RCall hosts one embedded R session per process, and R is neither thread-safe
# nor reentrant. The pipeline stages (on spawned job threads) and the NMDS,
# PERMANOVA, and alpha-significance analyses (on HTTP handler tasks) all evaluate
# against that one interpreter.
#
# These once guarded it with two separate `_r_lock` objects, one in `Analysis` and
# one in the pipeline route, which is a data race rather than mutual exclusion: a
# pipeline stage resets the workspace with `rm(list=ls())` on acquisition and
# would destroy globals an analysis was midway through evaluating. A single user
# was enough to provoke it, since a pipeline runs on a background thread while the
# browser stays live.

if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end
SV = Main.Server

using MetaManifold.RRuntime
const RR = MetaManifold.RRuntime

@testset "R runtime" begin

    ## The regression itself: there must be exactly one lock over the one
    # interpreter, and every caller must reach it by the same path.
    @testset "exactly one lock guards the interpreter" begin
        @test !isdefined(MetaManifold.Analysis, :_r_lock)
        @test !isdefined(SV, :_r_lock)
        @test MetaManifold.Analysis.with_r_lock === RR.with_r_lock
        @test SV.with_r_lock                    === RR.with_r_lock
    end

    @testset "the lock is exclusive across tasks" begin
        @test !RR.r_busy()

        held    = Channel{Bool}(1)
        release = Channel{Bool}(1)
        holder = Threads.@spawn RR.with_r_lock() do
            put!(held, true)
            take!(release)      # hold the runtime until the test says otherwise
            :done
        end

        take!(held)
        @test RR.r_busy()
        # A pipeline stage waits indefinitely, so it cannot be tested for
        # give-up behaviour; an interactive analysis passes a timeout and must
        # refuse to hang behind the run.
        @test_throws RR.RBusyError RR.with_r_lock(() -> :never; timeout=0.1)

        put!(release, true)
        @test fetch(holder) == :done
        @test !RR.r_busy()
    end

    @testset "an uncontended acquire runs and returns" begin
        @test RR.with_r_lock(() -> 6 * 7) == 42
        @test RR.with_r_lock(() -> 6 * 7; timeout=5) == 42
        @test !RR.r_busy()
    end

    ## The lock is reentrant, so a locked helper calling another locked helper on
    # the same task must not deadlock against itself.
    @testset "the lock is reentrant within a task" begin
        result = RR.with_r_lock() do
            RR.with_r_lock(() -> :inner)
        end
        @test result == :inner
        @test !RR.r_busy()
    end

    ## An analysis degrades rather than failing when a pipeline holds the runtime:
    # the boxplot is still worth drawing, just without its significance annotation.
    @testset "alpha significance degrades while the runtime is busy" begin
        held    = Channel{Bool}(1)
        release = Channel{Bool}(1)
        holder = Threads.@spawn RR.with_r_lock() do
            put!(held, true)
            take!(release)
            :done
        end
        take!(held)

        previous = MetaManifold.Analysis.R_WAIT_SECONDS[]
        MetaManifold.Analysis.R_WAIT_SECONDS[] = 0.1
        try
            p, pairs = MetaManifold.Analysis._alpha_significance(
                [1.0, 2.0, 3.0, 4.0], ["a", "a", "b", "b"], ["s1", "s2", "s3", "s4"])
            @test isnothing(p)
            @test nrow(pairs) == 0
        finally
            MetaManifold.Analysis.R_WAIT_SECONDS[] = previous
            put!(release, true)
        end
        @test fetch(holder) == :done
    end

end
