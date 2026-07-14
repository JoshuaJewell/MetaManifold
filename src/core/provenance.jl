module Provenance

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

## Provenance capture
# A run's outputs are unusable as evidence unless the software that produced them
# can be named and proved. This module owns the whole of that concern, so that no
# other module learns how a version is obtained: it probes every component a run
# will invoke, identifies each by content rather than by its own claim, enforces
# the strictness policy, and emits the Attestation.
#
# Two invariants govern everything below.
#
# Fidelity. A version string is an assertion; a hash is evidence. vsearch and swarm
# were installed from `releases/latest`, so two machines reporting the same version
# may hold different binaries. Every external binary is therefore recorded by
# resolved path, version, AND the SHA256 of the binary itself.
#
# Per stage, not per run. A run directory is an accretion, not one execution: the
# Nutria_CvL forensics established that one run's stages were executed across eight
# dates spanning three and a half months. The versions behind one run's outputs may
# therefore legitimately differ between its stages, and a single per-run `tools:`
# block would be false precisely for the runs that most need an honest record. Each
# stage carries its own captured environment; the run-level summary is derived from
# the stages and marked `uniform: false` when they disagree.

using Dates, SHA, YAML, OrderedCollections
import RCall
using ..RRuntime: with_r_lock

export ProbeFailure, DatabaseReleaseMismatch,
       ToolProbe, TOOL_PROBES, ToolRecord, JuliaRecord, RRecord,
       DatabaseFormatSpec, DatabaseFormatRecord, DatabaseRecord,
       CapturedEnvironment, Attestation,
       probe_tool, probe_julia, probe_r, probe_database, probe_host, probe_metamanifold,
       preflight, required_components, required_database, strict_mode,
       record_stage!, write_attestation, read_attestation, merge_attestations,
       render_attestation, output_record, file_sha256, cached_sha256,
       parse_asset_release, database_specs

const SCHEMA_VERSION = 1

## Failures
# A probe that cannot prove a component throws. Whether that aborts the run or
# merely degrades it is the strictness policy's business, decided in `preflight`,
# never here.
struct ProbeFailure <: Exception
    component :: String
    reason    :: String
end

Base.showerror(io::IO, e::ProbeFailure) = print(io,
    "provenance: could not prove '$(e.component)': $(e.reason)")

# A release disagreement between the formats of one logical database is a
# scientific error, not a probe failure: the dual-classifier consensus compares
# DADA2 and VSEARCH labels for string equality, so references drawn from different
# releases score genuine agreements as disagreements. No override may launder it.
struct DatabaseReleaseMismatch <: Exception
    database :: String
    releases :: OrderedDict{String,String}
end

Base.showerror(io::IO, e::DatabaseReleaseMismatch) = print(io,
    "provenance: the formats of database '$(e.database)' derive from different " *
    "releases, which confounds the dual-classifier consensus: " *
    join(("$fmt=$rel" for (fmt, rel) in e.releases), ", "))

## Repository anchor
repo_root() = normpath(joinpath(@__DIR__, "..", ".."))

timestamp() = Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ")

## Hashing
file_sha256(path::AbstractString) = open(io -> bytes2hex(sha256(io)), path, "r")

sidecar_path(path::AbstractString) = path * ".sha256.yml"

"""
    cached_sha256(path; sidecar=sidecar_path(path)) -> String

SHA256 of `path`, cached in a sidecar keyed by the file's size and mtime.

Hashing a multi-gigabyte reference FASTA on every run is wasteful, so the hash is
computed once and re-read while size and mtime agree with the sidecar, and
recomputed the moment they do not. A missing, unreadable, or stale sidecar is a
cache miss and never a run failure; an unwritable directory costs the cache, not
the hash.
"""
function cached_sha256(path::AbstractString; sidecar::AbstractString = sidecar_path(path))
    st       = stat(path)
    size     = Int(st.size)
    # Seconds are too coarse to notice a file replaced within the same second.
    mtime_us = round(Int, st.mtime * 1_000_000)

    if isfile(sidecar)
        try
            rec = YAML.load_file(sidecar)
            if get(rec, "size", nothing) == size && get(rec, "mtime_us", nothing) == mtime_us
                cached = get(rec, "sha256", nothing)
                cached isa AbstractString && return String(cached)
            end
        catch err
            @warn "Provenance: ignoring unreadable hash sidecar $sidecar" exception=err
        end
    end

    hash = file_sha256(path)
    try
        YAML.write_file(sidecar, OrderedDict{String,Any}(
            "file"     => basename(path),
            "sha256"   => hash,
            "size"     => size,
            "mtime_us" => mtime_us,
        ))
    catch err
        @warn "Provenance: could not write hash sidecar $sidecar" exception=err
    end
    return hash
end

## Version parsers
# Each tool announces itself differently, and at least two lie about where. Nothing
# here may assume uniformity: vsearch and swarm write their banner to stderr and
# leave stdout to the citation notice; cd-hit-est has no --version flag at all and
# hides its version in the `-h` output, which it prints while exiting non-zero.
#
# This is exactly the code that rots silently when an upstream tool changes its
# banner, so every parser is pinned to captured output from the real binary in
# test/fixtures/provenance.

function _capture(re::Regex, text::AbstractString, component::AbstractString)
    m = match(re, text)
    isnothing(m) && throw(ProbeFailure(component,
        "no version in the probe output: $(repr(first(strip(text), 120)))"))
    return String(m.captures[1])
end

# cutadapt prints a bare version and nothing else, so anything more is a changed
# banner and must fail rather than be guessed at.
parse_cutadapt_version(text::AbstractString) =
    _capture(r"^\s*v?([0-9][^\s]*)\s*$"m, text, "cutadapt")

parse_fastqc_version(text::AbstractString) =
    _capture(r"FastQC\s+v([0-9][^\s]*)"i, text, "fastqc")

parse_multiqc_version(text::AbstractString) =
    _capture(r"multiqc,?\s+version\s+([0-9][^\s]*)"i, text, "multiqc")

# The banner reads `vsearch v2.30.5_linux_x86_64, 15.3GB RAM, 24 cores`. The build
# suffix is part of what the binary calls itself and is kept; the RAM and core
# counts describe this machine, not the tool, and are dropped at the comma.
parse_vsearch_version(text::AbstractString) =
    _capture(r"vsearch\s+v([0-9][^\s,]*)"i, text, "vsearch")

parse_swarm_version(text::AbstractString) =
    _capture(r"^\s*Swarm\s+([0-9][^\s]*)"im, text, "swarm")

# `		====== CD-HIT version 4.8.1 (built on Aug 20 2021) ======`. The build date
# is not recorded: the binary's own SHA256 distinguishes two builds of one version
# far better than a date string does.
parse_cdhit_version(text::AbstractString) =
    _capture(r"CD-HIT\s+version\s+([0-9][^\s]*)"i, text, "cd-hit-est")

## The probe registry
# A declarative table of (component, probe command, parser). `key` is the
# config/tools.yml key and the name this module answers to; `name` is what the tool
# is called on a command line and in the Attestation.
struct ToolProbe
    key    :: String
    name   :: String
    args   :: Vector{String}
    stream :: Symbol            # the stream the version actually appears on
    parser :: Function
end

probed_by(p::ToolProbe) =
    join([p.name; p.args], " ") * (p.stream === :stderr ? " (stderr)" : "")

const TOOL_PROBES = OrderedDict{String,ToolProbe}(
    "cutadapt"   => ToolProbe("cutadapt",   "cutadapt",   ["--version"], :stdout, parse_cutadapt_version),
    "fastqc"     => ToolProbe("fastqc",     "fastqc",     ["--version"], :stdout, parse_fastqc_version),
    "multiqc"    => ToolProbe("multiqc",    "multiqc",    ["--version"], :stdout, parse_multiqc_version),
    "vsearch"    => ToolProbe("vsearch",    "vsearch",    ["--version"], :stderr, parse_vsearch_version),
    "swarm"      => ToolProbe("swarm",      "swarm",      ["--version"], :stderr, parse_swarm_version),
    "cd_hit_est" => ToolProbe("cd_hit_est", "cd-hit-est", ["-h"],        :stdout, parse_cdhit_version),
)

## Command execution
# Injectable so that the tests never shell out to a real binary. A probe's success
# is decided by whether its parser finds a version, never by the exit status:
# cd-hit-est exits 1 on `-h` and is nonetheless perfectly informative.
struct CommandOutput
    out  :: String
    err  :: String
    code :: Int
end

function run_command(argv::Vector{String})::CommandOutput
    out, err = IOBuffer(), IOBuffer()
    proc = run(pipeline(ignorestatus(Cmd(argv)); stdout=out, stderr=err))
    return CommandOutput(String(take!(out)), String(take!(err)), proc.exitcode)
end

# Tools is included after this module, so its resolver is reached at call time
# rather than bound at load time. A caller may inject its own; the tests do.
function default_bin_resolver(key::AbstractString)::String
    parent = parentmodule(@__MODULE__)
    isdefined(parent, :Tools) || return String(key)
    return String(getfield(parent, :Tools).tool_bin(key))
end

## Component records
struct ToolRecord
    name      :: String
    version   :: String
    path      :: String
    sha256    :: String
    probed_by :: String
end

struct JuliaRecord
    version         :: String
    manifest_sha256 :: String
end

struct RRecord
    version          :: String
    renv_lock_sha256 :: String
    packages         :: OrderedDict{String,String}
end

struct DatabaseFormatRecord
    format  :: String
    path    :: String
    sha256  :: String
    uri     :: String
    release :: String
end

struct DatabaseRecord
    name    :: String
    release :: String
    formats :: Vector{DatabaseFormatRecord}
end

"""
    probe_tool(probe; bin_resolver=default_bin_resolver, runner=run_command) -> ToolRecord

Resolve, probe, and hash one external binary.

The binary is identified by content as well as by claim: the record carries the
resolved absolute path and the SHA256 of the binary itself, so an Attestation
remains evidence even where the version string is not distinguishing.
"""
function probe_tool(probe::ToolProbe;
                    bin_resolver::Function = default_bin_resolver,
                    runner::Function       = run_command)
    bin  = bin_resolver(probe.key)
    path = Sys.which(bin)
    isnothing(path) &&
        throw(ProbeFailure(probe.name, "no executable binary at '$bin'"))
    path = String(path)

    output = try
        runner(String[path; probe.args])
    catch err
        throw(ProbeFailure(probe.name,
            "the probe command failed: $(sprint(showerror, err))"))
    end

    text    = probe.stream === :stderr ? output.err : output.out
    version = probe.parser(text)
    return ToolRecord(probe.name, version, path, file_sha256(path), probed_by(probe))
end

"""
    probe_julia(; manifest_path) -> JuliaRecord

Julia's own version, plus the SHA256 of the resolved `Manifest.toml`. The manifest
is what pins the dependency graph; the version alone does not.
"""
function probe_julia(; manifest_path::AbstractString = joinpath(repo_root(), "Manifest.toml"))
    isfile(manifest_path) ||
        throw(ProbeFailure("julia", "no Manifest.toml at $manifest_path"))
    return JuliaRecord(string(VERSION), file_sha256(manifest_path))
end

const R_PACKAGES = ["dada2", "Biostrings", "ShortRead", "vegan"]

"""
    r_version_query(pkg) -> String

The R expression that reads one package's version.

DESCRIPTION is the only authoritative source. `packageVersion` returns a
`numeric_version`, which treats `-` and `.` as equivalent separators, so
`as.character()` silently corrupts R's major.minor-patch convention: vegan's true
`2.7-3` is rendered `2.7.3` and Rcpp's `1.1.1-1.1` becomes `1.1.1.1.1`, which is
not even a well-formed R version. Two of five packages were misreported on this
machine. Nothing here may reach for it, and nothing normalises what DESCRIPTION
declares.
"""
r_version_query(pkg::AbstractString) = """
local({
  d <- tryCatch(utils::packageDescription("$pkg"), error = function(e) NULL)
  if (is.list(d) && !is.null(d[["Version"]])) as.character(d[["Version"]]) else NA_character_
})"""

"""
    probe_r(; packages=R_PACKAGES, renv_lock, timeout=60) -> RRecord

R's version, the SHA256 of `renv.lock`, and each named package's DESCRIPTION
version.

Every evaluation goes through the shared `RRuntime.with_r_lock`, since RCall hosts
one embedded interpreter for the whole process and a pipeline stage may hold it.
The `timeout` is what stops an interactive caller from hanging behind a run that
holds the runtime for hours; pass `nothing` to wait indefinitely.
"""
function probe_r(; packages::AbstractVector{<:AbstractString} = R_PACKAGES,
                   renv_lock::AbstractString = joinpath(repo_root(), "renv.lock"),
                   timeout::Union{Real,Nothing} = 60)
    isfile(renv_lock) ||
        throw(ProbeFailure("r", "no renv.lock at $renv_lock"))

    version, versions = try
        with_r_lock(; timeout) do
            r_version = RCall.rcopy(String, RCall.reval("R.version.string"))
            found = OrderedDict{String,String}()
            for pkg in packages
                raw = RCall.rcopy(RCall.reval(r_version_query(pkg)))
                raw isa AbstractString || throw(ProbeFailure("r",
                    "package '$pkg' is not installed in the R library in use"))
                found[String(pkg)] = String(raw)
            end
            (r_version, found)
        end
    catch err
        err isa ProbeFailure && rethrow()
        throw(ProbeFailure("r", sprint(showerror, err)))
    end

    return RRecord(version, file_sha256(renv_lock), versions)
end

## Reference databases
struct DatabaseFormatSpec
    format :: String
    path   :: String
    uri    :: String            # empty when the entry declares no source
end

const _PR2_ASSET   = r"_version_([0-9]+(?:\.[0-9]+)+)_"
const _ANY_RELEASE = r"[_-]v?([0-9]+(?:\.[0-9]+)+)[_.-]"

"""
    parse_asset_release(asset) -> String

The release an asset declares in its own filename.

The filename is authoritative and the release tag is not. PR2 names its assets
`pr2_version_<release>_SSU_<format>.fasta.gz`, and upstream the two disagree: tag
`v5.1.0.0` carries assets named `5.1.0`. The release recorded in an Attestation is
what the database actually is, not where it happened to be found, so only the last
component of a URI is ever read.
"""
function parse_asset_release(asset::AbstractString)
    name = basename(rstrip(String(asset), '/'))
    m = match(_PR2_ASSET, name)
    isnothing(m) && (m = match(_ANY_RELEASE, name))
    isnothing(m) && throw(ProbeFailure(name,
        "no release could be parsed from the asset filename"))
    return String(m.captures[1])
end

_try_release(asset::AbstractString) =
    try parse_asset_release(asset) catch; nothing end

function _format_release(db::AbstractString, spec::DatabaseFormatSpec)
    component  = "database $db.$(spec.format)"
    from_file  = _try_release(spec.path)
    from_uri   = isempty(spec.uri) ? nothing : _try_release(spec.uri)
    # A file whose name declares a different release from the asset it is supposed
    # to be is not a naming quirk; it is the wrong file.
    if !isnothing(from_file) && !isnothing(from_uri) && from_file != from_uri
        throw(ProbeFailure(component,
            "the file on disk is not the asset its uri names: " *
            "$(basename(spec.path)) declares release $from_file, " *
            "$(basename(spec.uri)) declares $from_uri"))
    end
    release = something(from_file, from_uri, Some(nothing))
    isnothing(release) && throw(ProbeFailure(component,
        "no release could be parsed from '$(basename(spec.path))' or its uri"))
    return release
end

"""
    probe_database(name, formats) -> DatabaseRecord

Hash and date every format of one logical database, and refuse a release
disagreement between them.

The same-release rule converts a class of silent scientific error into a startup
failure, and it is not subject to the strictness override: a run whose two
classifiers consult different releases of one reference produces a consensus score
that is confounded, and no `degraded: true` marking makes that number safe.
"""
function probe_database(name::AbstractString, formats::AbstractVector{DatabaseFormatSpec})
    isempty(formats) && throw(ProbeFailure("database $name", "no formats are configured"))

    records = DatabaseFormatRecord[]
    for spec in formats
        isfile(spec.path) || throw(ProbeFailure("database $name.$(spec.format)",
            "no file at $(spec.path)"))
        push!(records, DatabaseFormatRecord(spec.format, abspath(spec.path),
                                            cached_sha256(spec.path), spec.uri,
                                            _format_release(name, spec)))
    end

    releases = unique(r.release for r in records)
    length(releases) == 1 || throw(DatabaseReleaseMismatch(String(name),
        OrderedDict{String,String}(r.format => r.release for r in records)))

    return DatabaseRecord(String(name), first(releases), records)
end

"""
    database_specs(db_config, name; resolved) -> Vector{DatabaseFormatSpec}

Read the `databases:<name>:` section of a loaded databases.yml and pair each
format with its resolved local path.

`resolved` is keyed as `Databases.ensure_databases` keys it, `"<name>_<format>"`.
A format absent from `resolved` falls back to its `local:` path, then to the
cached download under `databases.dir`.
"""
function database_specs(db_config::AbstractDict, name::AbstractString;
                        resolved::AbstractDict = Dict{String,String}())
    section = get(db_config, "databases", nothing)
    section isa AbstractDict ||
        throw(ProbeFailure("database $name", "the config declares no `databases:` section"))
    entry = get(section, name, nothing)
    entry isa AbstractDict ||
        throw(ProbeFailure("database $name", "the config declares no database '$name'"))

    dir   = abspath(string(get(section, "dir", "./databases")))
    specs = DatabaseFormatSpec[]
    for (fmt, info) in entry
        info isa AbstractDict || continue
        uri   = get(info, "uri", nothing)
        local_path = get(info, "local", nothing)
        (isnothing(uri) && isnothing(local_path)) && continue

        key  = "$(name)_$(fmt)"
        path = if haskey(resolved, key)
            string(resolved[key])
        elseif !isnothing(local_path) && !isempty(string(local_path))
            string(local_path)
        elseif !isnothing(uri)
            joinpath(dir, basename(string(uri)))
        else
            continue
        end
        push!(specs, DatabaseFormatSpec(string(fmt), path,
                                        isnothing(uri) ? "" : string(uri)))
    end
    sort!(specs, by = s -> s.format)
    return specs
end

## Host and MetaManifold itself
function probe_host()
    return OrderedDict{String,Any}(
        "os"       => _os_string(),
        "arch"     => string(Sys.ARCH),
        "hostname" => gethostname(),
    )
end

function _os_string()
    release = try
        String(readchomp(`uname -r`))
    catch
        ""
    end
    return isempty(release) ? string(Sys.KERNEL) : "$(Sys.KERNEL) $release"
end

"""
    probe_metamanifold(; root=repo_root()) -> OrderedDict

MetaManifold's own identity. A dirty working tree is itself a provenance fact and
is recorded rather than refused; an unknowable field is left null rather than
filled from a plausible guess.
"""
function probe_metamanifold(; root::AbstractString = repo_root())
    return OrderedDict{String,Any}(
        "version"   => _project_version(root),
        "git_sha"   => _git_output(root, "rev-parse", "HEAD"),
        "git_dirty" => _git_dirty(root),
    )
end

function _project_version(root::AbstractString)
    path = joinpath(root, "Project.toml")
    isfile(path) || return nothing
    for line in eachline(path)
        m = match(r"^\s*version\s*=\s*\"([^\"]+)\"", line)
        isnothing(m) || return String(m.captures[1])
    end
    return nothing
end

function _git_output(root::AbstractString, args::AbstractString...)
    try
        return String(readchomp(`git -C $root $(collect(args))`))
    catch
        return nothing
    end
end

function _git_dirty(root::AbstractString)
    status = _git_output(root, "status", "--porcelain")
    return isnothing(status) ? nothing : !isempty(status)
end

## The captured environment
struct CapturedEnvironment
    julia               :: Union{JuliaRecord,Nothing}
    r                   :: Union{RRecord,Nothing}
    tools               :: OrderedDict{String,ToolRecord}
    databases           :: OrderedDict{String,DatabaseRecord}
    degraded            :: Bool
    degraded_components :: Vector{String}
end

CapturedEnvironment(; julia=nothing, r=nothing,
                      tools=OrderedDict{String,ToolRecord}(),
                      databases=OrderedDict{String,DatabaseRecord}(),
                      degraded_components=String[]) =
    CapturedEnvironment(julia, r, tools, databases,
                        !isempty(degraded_components), degraded_components)

function _enabled(config::AbstractDict, section::AbstractString, default::Bool)
    entry = get(config, section, nothing)
    entry isa AbstractDict || return default
    return get(entry, "enabled", default) === true
end

"""
    required_components(config) -> Vector{String}

The components a run with this config will actually invoke.

Preflight resolves exactly this set, so a run with `swarm.enabled: false` neither
requires nor records swarm. Cutadapt and the QC pair carry no `enabled` key and
always run; the DADA2 stages make R and its packages unconditional.
"""
function required_components(config::AbstractDict)
    components = String["julia", "r", "cutadapt", "fastqc", "multiqc"]
    _enabled(config, "vsearch", true)  && push!(components, "vsearch")
    _enabled(config, "swarm",   true)  && push!(components, "swarm")
    _enabled(config, "cdhit",   false) && push!(components, "cd_hit_est")
    return components
end

"""
    required_database(config) -> Union{String,Nothing}

The reference database the run will consult, or `nothing` when it will consult
none. Both classifiers draw on the one key, which is why they must agree on a
release.
"""
function required_database(config::AbstractDict)
    dada2 = get(config, "dada2", nothing)
    taxonomy = dada2 isa AbstractDict ? get(dada2, "taxonomy", nothing) : nothing
    assigns = taxonomy isa AbstractDict ? get(taxonomy, "enabled", true) === true : false
    (assigns || _enabled(config, "vsearch", true)) || return nothing
    name = taxonomy isa AbstractDict ? get(taxonomy, "database", "pr2") : "pr2"
    return string(name)
end

"""
    strict_mode(config) -> Bool

Strict unless the run config explicitly says otherwise. The override must be
exercised deliberately, so an absent, malformed, or null `provenance:` section
means strict.
"""
function strict_mode(config::AbstractDict)
    section = get(config, "provenance", nothing)
    section isa AbstractDict || return true
    return get(section, "strict", true) === true
end

"""
    preflight(config; databases, strict, ...) -> CapturedEnvironment

Probe every component the run will invoke, before any compute.

Probing is a phase, not a side effect scattered through the stages: a failure must
abort here, not forty minutes into DADA2. That ordering is what makes strict mode
usable rather than infuriating.

Under `strict` (the default) a failed probe raises and nothing is computed. Under
the override the run proceeds and the environment is marked degraded, naming
exactly the components that could not be proved. A database release mismatch is
outside the policy and raises either way.

`databases` maps a database name to its `DatabaseFormatSpec`s; build it with
`database_specs`. The probers are injectable so that tests need neither R nor the
external binaries.
"""
function preflight(config::AbstractDict;
                   databases::AbstractDict     = OrderedDict{String,Vector{DatabaseFormatSpec}}(),
                   strict::Bool                = strict_mode(config),
                   bin_resolver::Function      = default_bin_resolver,
                   runner::Function            = run_command,
                   julia_prober::Function      = probe_julia,
                   r_prober::Function          = probe_r,
                   tool_prober::Function       = probe -> probe_tool(probe; bin_resolver, runner),
                   database_prober::Function   = (name, specs) -> probe_database(name, specs))
    julia    = nothing
    r        = nothing
    tools    = OrderedDict{String,ToolRecord}()
    records  = OrderedDict{String,DatabaseRecord}()
    degraded = String[]

    for component in required_components(config)
        try
            if component == "julia"
                julia = julia_prober()
            elseif component == "r"
                r = r_prober()
            else
                tools[component] = tool_prober(TOOL_PROBES[component])
            end
        catch err
            err isa ProbeFailure || rethrow()
            strict && rethrow()
            push!(degraded, component)
            @warn "Provenance: '$component' could not be proved; this run is degraded" reason=err.reason
        end
    end

    for (name, specs) in databases
        try
            records[String(name)] = database_prober(String(name), specs)
        catch err
            # DatabaseReleaseMismatch is not a ProbeFailure and so escapes here,
            # strict or not, by design.
            err isa ProbeFailure || rethrow()
            strict && rethrow()
            push!(degraded, "database:$name")
            @warn "Provenance: database '$name' could not be proved; this run is degraded" reason=err.reason
        end
    end

    return CapturedEnvironment(julia, r, tools, records, !isempty(degraded), degraded)
end

## Serialisation of records
as_yaml(t::ToolRecord) = OrderedDict{String,Any}(
    "version"   => t.version,
    "path"      => t.path,
    "sha256"    => t.sha256,
    "probed_by" => t.probed_by,
)

as_yaml(j::JuliaRecord) = OrderedDict{String,Any}(
    "version"         => j.version,
    "manifest_sha256" => j.manifest_sha256,
)

as_yaml(r::RRecord) = OrderedDict{String,Any}(
    "version"          => r.version,
    "renv_lock_sha256" => r.renv_lock_sha256,
    "packages"         => OrderedDict{String,Any}(k => v for (k, v) in r.packages),
)

as_yaml(f::DatabaseFormatRecord) = OrderedDict{String,Any}(
    "path"   => f.path,
    "sha256" => f.sha256,
    "uri"    => f.uri,
)

function as_yaml(d::DatabaseRecord)
    out = OrderedDict{String,Any}("release" => d.release)
    for fmt in d.formats
        out[fmt.format] = as_yaml(fmt)
    end
    return out
end

function runtimes_yaml(env::CapturedEnvironment)
    out = OrderedDict{String,Any}()
    isnothing(env.julia) || (out["julia"] = as_yaml(env.julia))
    isnothing(env.r)     || (out["r"]     = as_yaml(env.r))
    return out
end

tools_yaml(env::CapturedEnvironment) =
    OrderedDict{String,Any}(name => as_yaml(rec) for (name, rec) in env.tools)

databases_yaml(env::CapturedEnvironment) =
    OrderedDict{String,Any}(name => as_yaml(rec) for (name, rec) in env.databases)

"""
    output_record(path, root) -> OrderedDict

One output file as the Attestation carries it: the path relative to the run
directory, and its SHA256.
"""
output_record(path::AbstractString, root::AbstractString) = OrderedDict{String,Any}(
    "path"   => "./" * relpath(path, root),
    "sha256" => file_sha256(path),
)

## The Attestation
# The run's formal witness statement. The document is held as plain ordered
# dictionaries rather than a typed tree, so that reading one back is the same
# operation as building one and a round trip loses nothing.
mutable struct Attestation
    doc :: OrderedDict{String,Any}
end

"""
    Attestation(; run, config, config_sha256, root) -> Attestation

An empty Attestation for one run. `run` names the study, group, run, and start
time; `config` is embedded inline so the artefact stands alone.

Paths and command lines are recorded verbatim, and may carry a username or a study
name. The Attestation is a publishable artefact; this is documented rather than
silently sanitised, so what is being published is known.
"""
function Attestation(; run::AbstractDict = OrderedDict{String,Any}(),
                       config::Union{AbstractDict,Nothing} = nothing,
                       config_sha256::AbstractString = "",
                       root::AbstractString = repo_root())
    doc = OrderedDict{String,Any}(
        "schema_version"      => SCHEMA_VERSION,
        "generated"           => timestamp(),
        "degraded"            => false,
        "degraded_components" => String[],
        "uniform"             => true,
        "divergent"           => String[],
        "run"                 => OrderedDict{String,Any}(string(k) => v for (k, v) in run),
        "metamanifold"        => probe_metamanifold(; root),
        "host"                => probe_host(),
        "runtimes"            => OrderedDict{String,Any}(),
        "tools"               => OrderedDict{String,Any}(),
        "databases"           => OrderedDict{String,Any}(),
        "config"              => OrderedDict{String,Any}(
            "run_config_sha256" => String(config_sha256),
            "run_config"        => config,
        ),
        "stages"              => Any[],
    )
    return Attestation(doc)
end

stages(att::Attestation) = att.doc["stages"]

_stage_index(att::Attestation, name::AbstractString) =
    findfirst(s -> get(s, "name", nothing) == String(name), stages(att))

"""
    record_stage!(att, name, env; started, finished, status, commands, outputs) -> Attestation

Record one stage's own captured environment, replacing any earlier record of that
stage.

Re-running a single stage of an existing run must update that stage alone, because
a run directory is an accretion and the other stages' records remain true. The
run-level summary is re-derived on every call.
"""
function record_stage!(att::Attestation, name::AbstractString, env::CapturedEnvironment;
                       started::AbstractString  = "",
                       finished::AbstractString = timestamp(),
                       status::AbstractString   = "ok",
                       commands::AbstractVector = String[],
                       outputs::AbstractVector  = OrderedDict{String,Any}[])
    stage = OrderedDict{String,Any}(
        "name"                => String(name),
        "started"             => String(started),
        "finished"            => String(finished),
        "status"              => String(status),
        "degraded"            => env.degraded,
        "degraded_components" => copy(env.degraded_components),
        "runtimes"            => runtimes_yaml(env),
        "tools"               => tools_yaml(env),
        "databases"           => databases_yaml(env),
        "commands"            => String[String(c) for c in commands],
        "outputs"             => Any[OrderedDict{String,Any}(string(k) => v for (k, v) in o)
                                     for o in outputs],
    )
    index = _stage_index(att, name)
    isnothing(index) ? push!(stages(att), stage) : (stages(att)[index] = stage)
    return summarise!(att)
end

"""
    summarise!(att) -> Attestation

Derive the run-level summary from the stages.

The summary is a convenience, never a source of truth: where two stages of one run
disagree about a component, the run is marked `uniform: false` and the disagreeing
components are named, so a heterogeneous run is visible at a glance without being
blocked. The latest stage to record a component supplies the summary's value for
it.
"""
function summarise!(att::Attestation)
    divergent = String[]
    for section in ("runtimes", "tools", "databases")
        merged = OrderedDict{String,Any}()
        for stage in stages(att)
            block = get(stage, section, nothing)
            block isa AbstractDict || continue
            for (key, value) in block
                haskey(merged, key) && merged[key] != value && push!(divergent, "$section.$key")
                merged[key] = value
            end
        end
        att.doc[section] = merged
    end
    att.doc["divergent"] = unique!(divergent)
    att.doc["uniform"]   = isempty(divergent)

    degraded = String[]
    for stage in stages(att)
        for component in get(stage, "degraded_components", ())
            push!(degraded, string(component))
        end
    end
    att.doc["degraded_components"] = unique!(degraded)
    att.doc["degraded"]            = !isempty(degraded)
    return att
end

"""
    merge_attestations(old, new) -> Attestation

Fold `new` over `old`: `new`'s stages replace those of the same name and are
otherwise appended, and `old`'s untouched stages survive intact. Everything else
is taken from `new`.
"""
function merge_attestations(old::Attestation, new::Attestation)
    merged_stages = Any[stage for stage in stages(old)]
    for stage in stages(new)
        index = findfirst(s -> get(s, "name", nothing) == get(stage, "name", nothing),
                          merged_stages)
        isnothing(index) ? push!(merged_stages, stage) : (merged_stages[index] = stage)
    end
    merged = Attestation(copy(new.doc))
    merged.doc["stages"] = merged_stages
    return summarise!(merged)
end

"""
    write_attestation(att, path; merge_existing=true) -> String

Emit `attestation.yml`, folding the new stages over whatever is already recorded
there so that re-running one stage rewrites that stage alone.
"""
function write_attestation(att::Attestation, path::AbstractString; merge_existing::Bool = true)
    document = merge_existing && isfile(path) ? merge_attestations(read_attestation(path), att) : att
    summarise!(document)
    document.doc["generated"] = timestamp()
    mkpath(dirname(abspath(path)))
    YAML.write_file(path, document.doc)
    return path
end

function read_attestation(path::AbstractString)
    doc = YAML.load_file(path; dicttype=OrderedDict{String,Any})
    # YAML narrows a homogeneous sequence, which would refuse a later stage of a
    # different shape; the stage list must stay open.
    doc["stages"] = Any[stage for stage in get(doc, "stages", ())]
    return Attestation(doc)
end

"""
    render_attestation(att) -> String

A human-readable rendering of the same data, for the header of `pipeline.log`, so
that the plain-text log remains self-sufficient. A degraded run stays visibly
degraded wherever its record travels.
"""
function render_attestation(att::Attestation)
    doc = att.doc
    io  = IOBuffer()
    println(io, "Attestation (schema $(get(doc, "schema_version", SCHEMA_VERSION)), generated $(get(doc, "generated", "")))")

    if get(doc, "degraded", false) === true
        println(io, "  DEGRADED: this run could not prove ",
                join(get(doc, "degraded_components", String[]), ", "),
                ". Its outputs are not fully attributable.")
    end
    if get(doc, "uniform", true) !== true
        println(io, "  NOT UNIFORM: stages of this run disagree about ",
                join(get(doc, "divergent", String[]), ", "),
                ". The per-stage records below are authoritative.")
    end

    mm = get(doc, "metamanifold", OrderedDict{String,Any}())
    println(io, "  MetaManifold: ", something(get(mm, "git_sha", nothing), "unknown"),
            get(mm, "git_dirty", false) === true ? " (dirty tree)" : "")

    for (name, block) in get(doc, "runtimes", OrderedDict{String,Any}())
        println(io, "  runtime ", name, ": ", get(block, "version", "?"))
        for (pkg, version) in get(block, "packages", OrderedDict{String,Any}())
            println(io, "    ", pkg, ": ", version)
        end
    end
    for (name, block) in get(doc, "tools", OrderedDict{String,Any}())
        println(io, "  tool ", name, ": ", get(block, "version", "?"),
                "  sha256:", first(string(get(block, "sha256", "")), 12),
                "  ", get(block, "path", ""))
    end
    for (name, block) in get(doc, "databases", OrderedDict{String,Any}())
        println(io, "  database ", name, ": release ", get(block, "release", "?"))
    end
    for stage in get(doc, "stages", Any[])
        println(io, "  stage ", get(stage, "name", "?"), ": ", get(stage, "status", "?"),
                " (", get(stage, "finished", ""), ")")
    end
    return String(take!(io))
end

end # module Provenance
