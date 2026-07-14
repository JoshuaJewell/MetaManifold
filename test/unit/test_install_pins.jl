using Test
using YAML
using JSON3
using SHA

## Pinning of external tools and runtimes
#
# These tests police the pins themselves rather than any behaviour of the pipeline.
# They exist because the failure they guard against is silent: an installer that
# takes whatever upstream published most recently still installs, still passes, and
# still produces results, and nothing anywhere records that two runs were made by
# different software. The only defence is to assert that the pins are declared, that
# they are declared in one place, and that every copy of them agrees.

const REPO_ROOT   = normpath(joinpath(@__DIR__, "..", ".."))
const PINS_PATH   = joinpath(REPO_ROOT, "config", "defaults", "tool_versions.yml")
const INSTALL_JL  = joinpath(REPO_ROOT, "install.jl")
const CI_PATH     = joinpath(REPO_ROOT, ".github", "workflows", "ci.yml")
const MANIFEST    = joinpath(REPO_ROOT, "Manifest.toml")
const RENV_LOCK   = joinpath(REPO_ROOT, "renv.lock")

# The tools the pipeline shells out to. A tool absent from the pin file is a tool
# nobody has decided the version of.
const EXPECTED_TOOLS = ["cutadapt", "fastqc", "multiqc", "vsearch", "cd_hit_est", "swarm"]

# The platforms install.jl can resolve an archive for, as "<OS_TYPE>-<ARCH_STR>".
const EXPECTED_PLATFORMS = ["linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64"]

is_sha256(s) = s isa AbstractString && occursin(r"^[0-9a-f]{64}$", s)

@testset "install pins" begin
    @test isfile(PINS_PATH)
    pins = YAML.load_file(PINS_PATH)

    @testset "every tool is pinned" begin
        @test pins["schema_version"] == 1
        @test sort(collect(keys(pins["tools"]))) == sort(EXPECTED_TOOLS)

        for tool in EXPECTED_TOOLS
            rec = pins["tools"][tool]
            version = get(rec, "version", nothing)
            @test version isa AbstractString
            @test !isempty(version)
            # "latest" is the absence of a pin wearing the costume of one.
            @test !occursin("latest", lowercase(version))
        end
    end

    @testset "every archive is checksummed" begin
        for tool in EXPECTED_TOOLS
            rec = pins["tools"][tool]
            rec["source"] == "pypi" && continue

            archives = rec["archives"]
            @test !isempty(archives)
            for (platform, archive) in archives
                url = get(archive, "url", nothing)
                @test url isa AbstractString
                @test startswith(url, "https://")
                # The version must be legible in the URL, or the pin and the artefact
                # it names can part company without anyone noticing.
                @test occursin(rec["version"], url)

                # A null checksum is permitted by the file's own documentation, but only
                # as an explicit, visible admission. It must never pass unremarked.
                sha = get(archive, "sha256", nothing)
                @test is_sha256(sha)
                sha === nothing && @warn "No SHA256 pinned for $tool on $platform; " *
                                         "that download cannot be verified."
            end
        end
    end

    @testset "binary tools are pinned for every supported platform" begin
        # FastQC is Java and cd-hit is built from source, so both are platform-neutral;
        # vsearch and swarm ship per-platform binaries and must cover what install.jl
        # will ask for.
        for tool in ("vsearch", "swarm")
            @test sort(collect(keys(pins["tools"][tool]["archives"]))) == sort(EXPECTED_PLATFORMS)
        end
        for tool in ("fastqc", "cd_hit_est")
            @test collect(keys(pins["tools"][tool]["archives"])) == ["any"]
        end
    end

    @testset "install.jl holds no versions of its own" begin
        src = read(INSTALL_JL, String)

        # The regression that prompted all of this: vsearch and swarm were installed
        # from whatever GitHub called newest that day.
        @test !occursin("releases/latest", src)
        @test !occursin("api.github.com", src)

        # Download URLs live in the pin file, so install.jl must carry none. Were one to
        # creep back, the pin file would cease to be the single source of truth and the
        # two would drift apart in silence.
        @test !occursin("https://github.com/torognes", src)
        @test !occursin("bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v", src)
        @test !occursin("github.com/weizhongli", src)

        @test occursin("tool_versions.yml", src)
    end

    @testset "runtime pins agree with the lockfiles" begin
        # The pin file does not lead the lockfiles; it restates them so that CI and the
        # installer can read a version the lockfiles hold in formats they cannot parse.
        julia_pin = pins["runtimes"]["julia"]["version"]
        manifest  = read(MANIFEST, String)
        m = match(r"julia_version\s*=\s*\"([^\"]+)\"", manifest)
        @test m !== nothing
        @test julia_pin == m[1]

        renv = JSON3.read(read(RENV_LOCK, String))
        @test pins["runtimes"]["r"]["version"] == renv["R"]["Version"]
        @test pins["runtimes"]["r"]["bioconductor"] == renv["Bioconductor"]["Version"]

        # The apt revision is how R is actually pinned on the CI runner, so it must name
        # the same R the lockfile does.
        @test startswith(pins["runtimes"]["r"]["apt_version"], pins["runtimes"]["r"]["version"] * "-")
    end

    @testset "the installer refuses what it cannot verify" begin
        # install.jl guards its own main(), so loading it here resolves the pins and
        # defines the helpers without installing anything.
        Installer = Module(:Installer)
        Base.include(Installer, INSTALL_JL)

        @test Installer.pinned_version("vsearch") == pins["tools"]["vsearch"]["version"]

        # Platform-specific archives are selected by platform; platform-neutral ones fall
        # back to the "any" entry rather than failing.
        vsearch = Installer.pinned_archive("vsearch")
        @test vsearch["url"] == pins["tools"]["vsearch"]["archives"][Installer.PLATFORM]["url"]
        @test Installer.pinned_archive("fastqc")["url"] ==
              pins["tools"]["fastqc"]["archives"]["any"]["url"]

        mktempdir() do dir
            payload = joinpath(dir, "payload.tar.gz")
            write(payload, "the bytes an installer was promised")
            actual = bytes2hex(open(SHA.sha256, payload))

            # The honest case: the hash agrees, and the file survives.
            @test Installer.verify_sha256(payload, actual, "payload.tar.gz") === nothing
            @test isfile(payload)

            # The dishonest case. Refusal must be loud, and the suspect file must not be
            # left lying about for the next run to pick up and trust.
            wrong = "0" ^ 64
            @test_throws ErrorException Installer.verify_sha256(payload, wrong, "payload.tar.gz")
            @test !isfile(payload)

            # An absent checksum is not permission to install unverified bytes.
            write(payload, "anything at all")
            @test_throws ErrorException Installer.verify_sha256(payload, nothing, "payload.tar.gz")
        end
    end

    @testset "CI installs what is pinned" begin
        ci = YAML.load_file(CI_PATH)
        matrix = ci["jobs"]["test"]["strategy"]["matrix"]

        # Julia is the one version CI cannot read from the pin file, because nothing can
        # be read before Julia exists. It is therefore duplicated, and this is the test
        # that makes the duplication safe.
        @test matrix["julia-version"] == [pins["runtimes"]["julia"]["version"]]

        # A floating runner would carry the R apt pin, which names a 24.04 build, off to
        # whatever the next LTS ships.
        @test matrix["os"] == ["ubuntu-24.04"]
        @test occursin("2404", pins["runtimes"]["r"]["apt_version"])

        # Everything else CI installs must be read from the pin file at run time rather
        # than written out beside it.
        steps = ci["jobs"]["test"]["steps"]
        runs  = join([get(step, "run", "") for step in steps], "\n")
        @test occursin("tool_versions.yml", runs)
        @test occursin("sha256sum -c", runs)

        for tool in ("vsearch", "swarm")
            @test !occursin(pins["tools"][tool]["version"], runs)
        end
    end
end
