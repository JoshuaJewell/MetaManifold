# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Per-invocation command capture for the embedded R stages. The shell tools log
# their resolved command line via PipelineLog.log_command; the DADA2 stages,
# which call R library functions rather than subprocesses, render the same
# command as one string that is both logged and evaluated (see DADA2._r_lit and
# DADA2._r_run_logged). These tests pin the rendering and prove that the one
# string reaches the log and executes.

using RCall

const _D = MetaManifold.DADA2

@testset "DADA2 command capture" begin

    @testset "_r_lit renders Julia values as R source text" begin
        @test _D._r_lit(true)  == "TRUE"
        @test _D._r_lit(false) == "FALSE"
        @test _D._r_lit(10)    == "10"
        @test _D._r_lit(0.75)  == "0.75"
        @test _D._r_lit(2.0)   == "2.0"
        @test _D._r_lit(nothing) == "NULL"
        @test _D._r_lit("pr2")   == "\"pr2\""
        # A vector becomes an R c(...) call; nesting resolves elementwise.
        @test _D._r_lit([240, 160])     == "c(240, 160)"
        @test _D._r_lit([2.0, 2.0])     == "c(2.0, 2.0)"
        @test _D._r_lit(["Domain", "Genus"]) == "c(\"Domain\", \"Genus\")"
        # A path with a quote or backslash stays a valid single R string literal.
        @test _D._r_lit("a\"b")  == "\"a\\\"b\""
        @test _D._r_lit("a\\b")  == "\"a\\\\b\""
    end

    @testset "a rendered filterAndTrim command parses and matches the call" begin
        # The scalar and vector parameters a scientist would need to reproduce the
        # run appear as R literals, in the call actually issued.
        cmd = "filter_stats <- filterAndTrim(mm_in_fwd, mm_out_fwd" *
              ", truncQ=$(_D._r_lit(2))" *
              ", truncLen=$(_D._r_lit([240, 160]))" *
              ", maxEE=$(_D._r_lit([2.0, 2.0]))" *
              ", verbose=$(_D._r_lit(true)))"
        @test occursin("truncLen=c(240, 160)", cmd)
        @test occursin("maxEE=c(2.0, 2.0)", cmd)
        @test occursin("verbose=TRUE", cmd)
        # R can parse it without error, which a malformed rendering would fail.
        @test rcopy(R"is.call(parse(text=$cmd)[[1]])")
    end

    @testset "_r_run_logged writes one marker and runs the same string" begin
        log_path = joinpath(mktempdir(), "stage.log")
        open(log_path, "w") do io; println(io, "=== stage ===") end

        # Mirror a stage: establish the sink, run through _r_run_logged, tear down.
        R"con <- file($log_path, open='at'); sink(con); sink(con, type='message')"
        try
            R"mm_fwd <- c(10, 20, 30)"
            _D._r_run_logged("res <- sum(mm_fwd) + $(_D._r_lit(100))")
        finally
            R"tryCatch({ sink(type='message'); sink(); close(con) }, error=function(e) NULL)"
        end

        # The command executed...
        @test rcopy(R"res") == 160
        # ...and exactly one recoverable marker line records the string that ran.
        cmd_lines = filter(l -> startswith(l, "[MetaManifold] cmd: "), readlines(log_path))
        @test length(cmd_lines) == 1
        @test cmd_lines[1] == "[MetaManifold] cmd: R> res <- sum(mm_fwd) + 100"
    end
end
