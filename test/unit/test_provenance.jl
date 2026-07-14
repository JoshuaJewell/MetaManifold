# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## Provenance
# The parsers are pinned to output captured from the real binaries on this machine,
# because a version probe is exactly the code that rots silently when an upstream
# tool changes its banner. Nothing here shells out to a tool or evaluates R unless
# the tool or the package is genuinely present, so the suite runs on a bare
# checkout.

using MetaManifold.Provenance
using OrderedCollections, YAML, SHA, Logging

const PV = MetaManifold.Provenance

const FIXTURES = joinpath(@__DIR__, "..", "fixtures", "provenance")
fixture(name) = read(joinpath(FIXTURES, name), String)

# A runner that replays captured output instead of executing anything.
canned(out::String, err::String = "", code::Int = 0) =
    argv -> PV.CommandOutput(out, err, code)

@testset "Provenance" begin

    @testset "version parsers, against captured tool output" begin
        ## cutadapt writes a bare version to stdout and nothing else.
        @test PV.parse_cutadapt_version(fixture("cutadapt_version_stdout.txt")) == "5.2"

        ## FastQC prefixes its name and a `v`.
        @test PV.parse_fastqc_version(fixture("fastqc_version_stdout.txt")) == "0.12.1"

        ## MultiQC uses a comma and the word `version`.
        @test PV.parse_multiqc_version(fixture("multiqc_version_stdout.txt")) == "1.33"

        ## vsearch writes its banner to STDERR, and the banner carries the build
        # suffix, which belongs to the binary, alongside this machine's RAM and core
        # counts, which do not.
        @test PV.parse_vsearch_version(fixture("vsearch_version_stderr.txt")) ==
              "2.30.5_linux_x86_64"

        ## swarm also writes to STDERR.
        @test PV.parse_swarm_version(fixture("swarm_version_stderr.txt")) == "3.1.6"

        ## cd-hit-est has no --version flag at all; the banner is in the `-h` output,
        # indented with tabs, and the command exits non-zero while printing it.
        @test PV.parse_cdhit_version(fixture("cd_hit_est_help_stdout.txt")) == "4.8.1"
    end

    @testset "a parser reading the wrong stream fails rather than inventing" begin
        # vsearch's stdout carries the citation notice and no version; swarm writes
        # nothing to stdout at all. A parser pointed at either must throw, not guess.
        @test_throws PV.ProbeFailure PV.parse_vsearch_version(fixture("vsearch_version_stdout.txt"))
        @test_throws PV.ProbeFailure PV.parse_swarm_version(fixture("swarm_version_stdout.txt"))
        @test_throws PV.ProbeFailure PV.parse_cutadapt_version("")
        @test_throws PV.ProbeFailure PV.parse_cdhit_version("Usage: cd-hit-est [Options]")
    end

    @testset "the registry knows which stream each tool speaks on" begin
        @test PV.TOOL_PROBES["vsearch"].stream    === :stderr
        @test PV.TOOL_PROBES["swarm"].stream      === :stderr
        @test PV.TOOL_PROBES["cutadapt"].stream   === :stdout
        @test PV.TOOL_PROBES["cd_hit_est"].args   == ["-h"]
        @test PV.probed_by(PV.TOOL_PROBES["vsearch"])  == "vsearch --version (stderr)"
        @test PV.probed_by(PV.TOOL_PROBES["cutadapt"]) == "cutadapt --version"
        @test PV.probed_by(PV.TOOL_PROBES["cd_hit_est"]) == "cd-hit-est -h"
    end

    @testset "a tool is identified by content, not by claim" begin
        mktempdir() do dir
            bin = joinpath(dir, "vsearch")
            write(bin, "#!/bin/sh\nexit 0\n")
            chmod(bin, 0o755)

            record = PV.probe_tool(PV.TOOL_PROBES["vsearch"];
                                   bin_resolver = _ -> bin,
                                   runner = canned("", fixture("vsearch_version_stderr.txt")))

            @test record.name    == "vsearch"
            @test record.version == "2.30.5_linux_x86_64"
            @test record.path    == bin
            # The hash is of the binary itself: two builds claiming one version, as
            # releases/latest cheerfully produces, are told apart only by this.
            @test record.sha256  == bytes2hex(sha256(read(bin)))
            @test record.probed_by == "vsearch --version (stderr)"
        end
    end

    @testset "an absent binary is a probe failure, not a silent gap" begin
        @test_throws PV.ProbeFailure PV.probe_tool(PV.TOOL_PROBES["swarm"];
            bin_resolver = _ -> "/nonexistent/swarm", runner = canned("Swarm 3.1.6"))
    end

    @testset "R package versions are read from DESCRIPTION, never packageVersion" begin
        ## The regression guard. packageVersion() returns a numeric_version, which
        # treats `-` and `.` as equivalent separators, so as.character() renders
        # vegan's true 2.7-3 as 2.7.3 and Rcpp's 1.1.1-1.1 as 1.1.1.1.1, which is not
        # even a well-formed R version. The query must never reach for it.
        query = PV.r_version_query("vegan")
        @test occursin("packageDescription", query)
        @test !occursin("packageVersion", query)
        @test occursin("Version", query)

        ## And the module as a whole must not smuggle it in elsewhere.
        source = read(joinpath(@__DIR__, "..", "..", "src", "core", "provenance.jl"), String)
        @test !occursin("packageVersion(", source)
    end

    @testset "the release comes from the asset filename, not the release tag" begin
        @test PV.parse_asset_release("pr2_version_5.1.1_SSU_dada2.fasta.gz") == "5.1.1"
        @test PV.parse_asset_release("pr2_version_5.1.0_SSU_taxo_long.fasta.gz") == "5.1.0"

        ## Upstream the tag and the filename disagree: tag v5.1.0.0 ships assets named
        # 5.1.0. What the database IS, is what the asset says it is.
        uri = "https://github.com/pr2database/pr2database/releases/download/v5.1.0.0/" *
              "pr2_version_5.1.0_SSU_dada2.fasta.gz"
        @test PV.parse_asset_release(uri) == "5.1.0"

        ## The milder case of the same disagreement, which the shipped config uses.
        tagged = "https://github.com/pr2database/pr2database/releases/download/v5.1.1/" *
                 "pr2_version_5.1.1_SSU_dada2.fasta.gz"
        @test PV.parse_asset_release(tagged) == "5.1.1"

        @test_throws PV.ProbeFailure PV.parse_asset_release("reference.fasta.gz")
    end

    @testset "databases: hashing, the sidecar cache, and the same-release rule" begin
        mktempdir() do dir
            dada2_name   = "pr2_version_5.1.1_SSU_dada2.fasta.gz"
            vsearch_name = "pr2_version_5.1.1_SSU_taxo_long.fasta.gz"
            stale_name   = "pr2_version_5.0.0_SSU_dada2.fasta.gz"
            for (name, content) in ((dada2_name, ">a\nACGT\n"),
                                    (vsearch_name, ">b\nTGCA\n"),
                                    (stale_name, ">c\nGGGG\n"))
                write(joinpath(dir, name), content)
            end
            base = "https://github.com/pr2database/pr2database/releases/download/v5.1.1/"

            record = PV.probe_database("pr2", [
                PV.DatabaseFormatSpec("dada2",   joinpath(dir, dada2_name),   base * dada2_name),
                PV.DatabaseFormatSpec("vsearch", joinpath(dir, vsearch_name), base * vsearch_name),
            ])
            @test record.release == "5.1.1"
            @test [f.format for f in record.formats] == ["dada2", "vsearch"]
            @test record.formats[1].sha256 == bytes2hex(sha256(read(joinpath(dir, dada2_name))))
            @test record.formats[1].uri    == base * dada2_name

            ## The hash is cached in a sidecar keyed by size and mtime, because
            # hashing a multi-gigabyte FASTA on every run is wasteful.
            sidecar = PV.sidecar_path(joinpath(dir, dada2_name))
            @test isfile(sidecar)
            cached = YAML.load_file(sidecar)
            @test cached["sha256"] == record.formats[1].sha256

            ## A stale sidecar must be disbelieved: overwrite the file and leave the
            # sidecar claiming the old hash, and the recomputed hash must win.
            write(joinpath(dir, dada2_name), ">a\nACGTACGT\n")
            touch(joinpath(dir, dada2_name))
            fresh = PV.cached_sha256(joinpath(dir, dada2_name))
            @test fresh == bytes2hex(sha256(read(joinpath(dir, dada2_name))))
            @test fresh != cached["sha256"]

            ## A hit is served from the sidecar, not recomputed: plant a hash that is
            # not the file's, leave size and mtime agreeing, and the planted value
            # must come back. That is what saves hashing a multi-gigabyte FASTA twice.
            hit_path = joinpath(dir, vsearch_name)
            planted  = YAML.load_file(PV.sidecar_path(hit_path))
            planted["sha256"] = "deadbeef"
            YAML.write_file(PV.sidecar_path(hit_path), planted)
            @test PV.cached_sha256(hit_path) == "deadbeef"

            ## The same-release rule. This is the exact defect the shipped defaults
            # once carried: DADA2 on PR2 5.0.0 and VSEARCH on 5.1.0. It confounds the
            # consensus score, so it is a hard error.
            @test_throws PV.DatabaseReleaseMismatch PV.probe_database("pr2", [
                PV.DatabaseFormatSpec("dada2",   joinpath(dir, stale_name),
                                      "https://example.invalid/v5.0.0/" * stale_name),
                PV.DatabaseFormatSpec("vsearch", joinpath(dir, vsearch_name), base * vsearch_name),
            ])

            ## A file that is not the asset its uri names is the wrong file.
            @test_throws PV.ProbeFailure PV.probe_database("pr2", [
                PV.DatabaseFormatSpec("dada2", joinpath(dir, stale_name), base * dada2_name),
            ])

            ## An absent file cannot be hashed and cannot be attested.
            @test_throws PV.ProbeFailure PV.probe_database("pr2", [
                PV.DatabaseFormatSpec("dada2", joinpath(dir, "absent.fasta.gz"), base * dada2_name),
            ])
        end
    end

    @testset "database specs are read from a databases.yml shape" begin
        cfg = YAML.load_file(joinpath(@__DIR__, "..", "..", "config", "defaults", "databases.yml"))
        specs = PV.database_specs(cfg, "pr2")
        @test [s.format for s in specs] == ["dada2", "vsearch"]
        # The shipped default must pin both formats to one release, or the consensus
        # score it produces is confounded.
        @test PV.parse_asset_release(specs[1].uri) == PV.parse_asset_release(specs[2].uri)

        resolved = Dict("pr2_dada2" => "/somewhere/pr2_version_5.1.1_SSU_dada2.fasta.gz")
        specs = PV.database_specs(cfg, "pr2"; resolved)
        @test specs[1].path == "/somewhere/pr2_version_5.1.1_SSU_dada2.fasta.gz"
    end

    @testset "preflight resolves exactly the components the config invokes" begin
        full = Dict("vsearch" => Dict("enabled" => true),
                    "swarm"   => Dict("enabled" => true),
                    "cdhit"   => Dict("enabled" => true))
        @test PV.required_components(full) ==
              ["julia", "r", "cutadapt", "fastqc", "multiqc", "vsearch", "swarm", "cd_hit_est"]

        ## A run with swarm off neither requires nor records swarm.
        lean = Dict("vsearch" => Dict("enabled" => true),
                    "swarm"   => Dict("enabled" => false),
                    "cdhit"   => Dict("enabled" => false))
        @test !("swarm" in PV.required_components(lean))
        @test !("cd_hit_est" in PV.required_components(lean))

        ## The factory defaults: vsearch and swarm on, cd-hit off.
        defaults = YAML.load_file(joinpath(@__DIR__, "..", "..", "config", "defaults", "pipeline.yml"))
        @test PV.required_components(defaults) ==
              ["julia", "r", "cutadapt", "fastqc", "multiqc", "vsearch", "swarm"]
        @test PV.required_database(defaults) == "pr2"
    end

    @testset "strictness" begin
        @test PV.strict_mode(Dict{String,Any}())
        @test PV.strict_mode(Dict("provenance" => Dict("strict" => true)))
        @test !PV.strict_mode(Dict("provenance" => Dict("strict" => false)))
        # A malformed or null section must not be read as an override.
        @test PV.strict_mode(Dict("provenance" => nothing))
    end

    ## A config that invokes only cutadapt among the probed binaries, so that a
    # preflight can be exercised without any tool being installed.
    minimal = Dict("vsearch" => Dict("enabled" => false),
                   "swarm"   => Dict("enabled" => false),
                   "cdhit"   => Dict("enabled" => false))

    fake_julia() = PV.JuliaRecord("1.12.5", "4b275a88")
    fake_r()     = PV.RRecord("R version 4.5.0 (2025-04-11)", "42848180",
                              OrderedDict("dada2" => "1.38.0", "vegan" => "2.7-3"))

    @testset "strict mode aborts at preflight, before any compute" begin
        threw = false
        try
            PV.preflight(minimal;
                         bin_resolver = _ -> "/nonexistent/tool",
                         runner       = canned(""),
                         julia_prober = fake_julia,
                         r_prober     = fake_r)
        catch err
            threw = true
            @test err isa PV.ProbeFailure
            @test occursin("cutadapt", err.component)
        end
        @test threw
    end

    @testset "the override permits the run and names what it could not prove" begin
        env = Logging.with_logger(Logging.NullLogger()) do
            PV.preflight(minimal;
                         strict       = false,
                         bin_resolver = _ -> "/nonexistent/tool",
                         runner       = canned(""),
                         julia_prober = fake_julia,
                         r_prober     = fake_r)
        end

        @test env.degraded
        @test env.degraded_components == ["cutadapt", "fastqc", "multiqc"]
        # What could be proved is still proved: degradation is per component.
        @test env.julia.version == "1.12.5"
        @test env.r.packages["vegan"] == "2.7-3"
        @test isempty(env.tools)
    end

    @testset "a database release mismatch escapes the override" begin
        mktempdir() do dir
            a = joinpath(dir, "pr2_version_5.0.0_SSU_dada2.fasta.gz")
            b = joinpath(dir, "pr2_version_5.1.0_SSU_taxo_long.fasta.gz")
            write(a, ">a\n"); write(b, ">b\n")
            specs = OrderedDict("pr2" => [PV.DatabaseFormatSpec("dada2", a, ""),
                                          PV.DatabaseFormatSpec("vsearch", b, "")])
            # No `degraded: true` marking makes a confounded consensus score safe, so
            # the override does not reach this.
            @test_throws PV.DatabaseReleaseMismatch Logging.with_logger(Logging.NullLogger()) do
                PV.preflight(minimal;
                             databases    = specs,
                             strict       = false,
                             bin_resolver = _ -> "/nonexistent/tool",
                             runner       = canned(""),
                             julia_prober = fake_julia,
                             r_prober     = fake_r)
            end
        end
    end

    ## Environments to attest with, standing in for probed ones.
    function env_with(cutadapt_version::String; degraded = String[])
        tools = OrderedDict("cutadapt" => PV.ToolRecord(
            "cutadapt", cutadapt_version, "/home/joshua/.local/bin/cutadapt",
            "72bae605", "cutadapt --version"))
        PV.CapturedEnvironment(PV.JuliaRecord("1.12.5", "4b275a88"), fake_r(),
                               tools, OrderedDict{String,PV.DatabaseRecord}(),
                               !isempty(degraded), degraded)
    end

    @testset "the Attestation records provenance per stage and round-trips" begin
        mktempdir() do dir
            path = joinpath(dir, "attestation.yml")
            att = PV.Attestation(; run = OrderedDict("study" => "Nutria_CvL",
                                                     "run"   => "Multiplex"),
                                   config = Dict("seed" => 123),
                                   config_sha256 = "3ac9")
            PV.record_stage!(att, "cutadapt", env_with("5.2");
                             started  = "2026-06-27T08:40:11Z",
                             finished = "2026-06-27T09:15:03Z",
                             commands = ["/home/joshua/.local/bin/cutadapt -m 200 in.fastq.gz"],
                             outputs  = [OrderedDict("path" => "./cutadapt/s1_R1.fastq.gz",
                                                     "sha256" => "1f4b")])
            PV.write_attestation(att, path)

            back = PV.read_attestation(path)
            @test back.doc["schema_version"] == 1
            @test back.doc["run"]["study"] == "Nutria_CvL"
            @test back.doc["config"]["run_config"]["seed"] == 123
            @test length(PV.stages(back)) == 1

            stage = PV.stages(back)[1]
            @test stage["name"] == "cutadapt"
            @test stage["tools"]["cutadapt"]["version"] == "5.2"
            # The command line is recorded verbatim, paths included; the Attestation
            # is publishable and this is a documented choice, not an oversight.
            @test occursin("-m 200", stage["commands"][1])
            @test stage["outputs"][1]["sha256"] == "1f4b"

            ## One stage, uniformly recorded, is a uniform run.
            @test back.doc["uniform"] === true
            @test back.doc["degraded"] === false
            @test back.doc["tools"]["cutadapt"]["version"] == "5.2"
        end
    end

    @testset "re-running one stage updates that stage alone" begin
        mktempdir() do dir
            path = joinpath(dir, "attestation.yml")

            first_pass = PV.Attestation()
            PV.record_stage!(first_pass, "cutadapt", env_with("5.2"); finished = "2026-03-26T10:00:00Z")
            PV.record_stage!(first_pass, "vsearch",  env_with("5.2"); finished = "2026-03-26T11:00:00Z")
            PV.write_attestation(first_pass, path)

            ## Months later, cutadapt alone is re-run, against a newer cutadapt. The
            # run directory is an accretion; vsearch's record from March remains true
            # and must survive untouched.
            second_pass = PV.Attestation()
            PV.record_stage!(second_pass, "cutadapt", env_with("5.3"); finished = "2026-06-27T10:00:00Z")
            PV.write_attestation(second_pass, path)

            back = PV.read_attestation(path)
            names = [s["name"] for s in PV.stages(back)]
            @test names == ["cutadapt", "vsearch"]

            cutadapt_stage = PV.stages(back)[1]
            vsearch_stage  = PV.stages(back)[2]
            @test cutadapt_stage["tools"]["cutadapt"]["version"] == "5.3"
            @test cutadapt_stage["finished"] == "2026-06-27T10:00:00Z"
            @test vsearch_stage["tools"]["cutadapt"]["version"]  == "5.2"
            @test vsearch_stage["finished"]  == "2026-03-26T11:00:00Z"

            ## The stages now disagree, and the run-level summary says so rather than
            # asserting a single tools block that was never true of the whole run.
            @test back.doc["uniform"] === false
            @test back.doc["divergent"] == ["tools.cutadapt"]
        end
    end

    @testset "a degraded stage marks the whole Attestation degraded" begin
        att = PV.Attestation()
        PV.record_stage!(att, "cutadapt", env_with("5.2"))
        PV.record_stage!(att, "swarm",    env_with("5.2"; degraded = ["swarm"]))

        @test att.doc["degraded"] === true
        @test att.doc["degraded_components"] == ["swarm"]

        ## And it stays visibly degraded wherever its record travels.
        rendering = PV.render_attestation(att)
        @test occursin("DEGRADED", rendering)
        @test occursin("swarm", rendering)
        @test occursin("tool cutadapt: 5.2", rendering)
    end

    @testset "outputs are recorded by content" begin
        mktempdir() do dir
            path = joinpath(dir, "cutadapt", "s1_R1.fastq.gz")
            mkpath(dirname(path))
            write(path, "reads")
            record = PV.output_record(path, dir)
            @test record["path"]   == "./cutadapt/s1_R1.fastq.gz"
            @test record["sha256"] == bytes2hex(sha256("reads"))
        end
    end

    @testset "MetaManifold records its own identity, dirt included" begin
        mm = PV.probe_metamanifold()
        @test mm["git_sha"] isa String && length(mm["git_sha"]) == 40
        # A dirty tree is itself a provenance fact, recorded rather than refused.
        @test mm["git_dirty"] isa Bool
        host = PV.probe_host()
        @test !isempty(host["hostname"])
        @test host["arch"] == string(Sys.ARCH)
    end

    @testset "julia is probed with its resolved Manifest" begin
        record = PV.probe_julia()
        @test record.version == string(VERSION)
        @test record.manifest_sha256 ==
              PV.file_sha256(joinpath(@__DIR__, "..", "..", "Manifest.toml"))
        @test_throws PV.ProbeFailure PV.probe_julia(manifest_path = "/nonexistent/Manifest.toml")
    end

    ## Live probes. Gated, so that the suite passes on a machine with neither the
    # binaries nor the R packages installed.
    @testset "live probes of what is actually installed" begin
        for (key, probe) in PV.TOOL_PROBES
            bin = PV.default_bin_resolver(key)
            if isnothing(Sys.which(bin))
                @info "Provenance: skipping live probe of $key, which is not installed"
                continue
            end
            record = PV.probe_tool(probe)
            @test !isempty(record.version)
            @test isabspath(record.path)
            @test length(record.sha256) == 64
        end

        r_ready = try
            PV.probe_r(; packages = String[], timeout = 30)
            true
        catch err
            @info "Provenance: skipping live R probe" reason=sprint(showerror, err)
            false
        end

        if r_ready
            record = PV.probe_r(; timeout = 120)
            @test occursin("R version", record.version)

            ## The bug this exists to prevent. renv.lock is the pin and DESCRIPTION is
            # what is loaded; they agree, and both keep R's major.minor-patch
            # convention that packageVersion() would flatten. vegan is the witness:
            # 2.7-3, never 2.7.3.
            lock = read(joinpath(@__DIR__, "..", "..", "renv.lock"), String)
            for (pkg, version) in record.packages
                @test occursin("\"$pkg\"", lock)
                @test occursin("\"Version\": \"$version\"", lock)
            end
            if haskey(record.packages, "vegan")
                @test occursin('-', record.packages["vegan"])
            end
        end
    end

end
