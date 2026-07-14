#!/usr/bin/env julia
#
# Dependency installer for MetaManifold
#
# Installs Julia deps, checks/downloads external CLI tools, and installs
# required R packages. Writes resolved tool paths to config/tools.yml.
#
# Usage via install.sh, or directly by:
#   julia --project=. install.jl [--update] [--modify] [--sysimage]
#
# Options:
#   --update    Re-assert the pinned tool versions and refresh managed binaries in bin/
#   --modify    Revisit configured tool paths instead of silently reusing them
#   --sysimage  After installation, compile a sysimage of all Julia deps to
#               speed up subsequent startup. Output: MetaManifold.so (.dylib on macOS)
#               Use with: julia --sysimage MetaManifold.so --project=. ...
#
# Pinning: every external tool version, download URL, and archive checksum lives in
# config/defaults/tool_versions.yml, and nothing in this script tracks "latest".
# Two clean installs a year apart therefore obtain the same binaries. --update
# re-fetches those same pins rather than advancing them, so it is idempotent; a
# version moves only when that file is edited. Any archive whose SHA256 does not
# match its pin is refused, not installed.

using Pkg

# False when the test suite loads this file to exercise the pin lookup and the
# checksum refusal. Nothing may be installed, and no dependency resolved, on a load
# that is not an install.
const RUNNING_AS_SCRIPT = abspath(PROGRAM_FILE) == abspath(@__FILE__)

if RUNNING_AS_SCRIPT
    @info "Installing Julia package dependencies..."
    Pkg.instantiate()
end

using YAML
using SHA
import Downloads

## Instantiate
const UPDATE_MODE   = "--update"   in ARGS
const MODIFY_MODE   = "--modify"   in ARGS
const SYSIMAGE_MODE = "--sysimage" in ARGS
const PROJECT_ROOT  = @__DIR__
const BIN_DIR       = joinpath(PROJECT_ROOT, "bin")
const CONFIG_DIR    = joinpath(PROJECT_ROOT, "config")
const TOOLS_CONFIG  = joinpath(CONFIG_DIR, "tools.yml")
const VERSIONS_FILE = joinpath(CONFIG_DIR, "defaults", "tool_versions.yml")

const OS_TYPE = Sys.islinux() ? "linux" :
                Sys.isapple() ? "macos" :
                error("Unsupported OS. Only Linux and macOS are supported.")

const ARCH_STR = Sys.ARCH == :x86_64  ? "x86_64"  :
                 Sys.ARCH == :aarch64 ? "aarch64" :
                 string(Sys.ARCH)

# Canonical binary name for tools whose config key differs from the binary name.
const BINARY_NAMES = Dict("cd_hit_est" => "cd-hit-est")
bin_name(key::String) = get(BINARY_NAMES, key, key)

mkpath(BIN_DIR)

## Version pins
# The pin file is the sole source of truth for what this installer fetches. Without
# it there is no defensible version to install, so its absence is fatal rather than
# an invitation to fall back on whatever upstream published most recently.
isfile(VERSIONS_FILE) || error(
    "Version pin file not found: $VERSIONS_FILE\n" *
    "It is committed to the repository; a checkout missing it is incomplete."
)
const PINS     = YAML.load_file(VERSIONS_FILE)
const PLATFORM = "$(OS_TYPE)-$(ARCH_STR)"

pinned_version(tool::String)::String = string(PINS["tools"][tool]["version"])

# The archive pinned for this platform, or the "any" entry for artefacts that are
# not platform-specific (FastQC is Java; cd-hit is compiled from source).
function pinned_archive(tool::String)::Dict
    archives = PINS["tools"][tool]["archives"]
    rec = get(archives, PLATFORM, get(archives, "any", nothing))
    rec === nothing && error(
        "No $tool archive is pinned for $PLATFORM in $VERSIONS_FILE.\n" *
        "Add one, with its SHA256, or install $tool yourself and give install.jl the path."
    )
    rec
end

## Config loading / saving
function load_tools_config()::Dict{String,Any}
    isfile(TOOLS_CONFIG) || return Dict{String,Any}()
    data = YAML.load_file(TOOLS_CONFIG)
    data isa Dict ? data : Dict{String,Any}()
end

function write_tools_config(config::Dict)
    mkpath(CONFIG_DIR)
    escaped = Dict{String,Any}()
    for key in sort(collect(keys(config)))
        val = config[key]
        path = val isa Dict ? get(val, "path", nothing) : val
        escaped[key] = Dict("path" => path)
    end

    yaml = YAML.write(escaped)
    open(TOOLS_CONFIG, "w") do io
        print(io, yaml)
    end
    @info "Config written to $TOOLS_CONFIG"
end

## Checking for tool
# Returns true if the binary at `path` is callable (local or remote SSH).
function check_tool(path::String)::Bool
    if occursin('@', path)
        # Remote SSH path: user@host:/path/to/binary
        colon_idx = findfirst(':', path)
        colon_idx === nothing && return false
        user_host = path[1:colon_idx-1]
        bin_path  = path[colon_idx+1:end]
        try
            run(pipeline(
                `ssh -o BatchMode=yes -o ConnectTimeout=5 $user_host test -x $bin_path`;
                stdout=devnull, stderr=devnull
            ))
            return true
        catch
            return false
        end
    else
        # Local path or bare name (PATH lookup)
        resolved = isfile(path) ? path : Sys.which(path)
        resolved === nothing && return false
        return Sys.isexecutable(resolved)
    end
end

"""Return the full path to `name` if it is in PATH, otherwise nothing."""
function find_in_path(name::String)
    Sys.which(name)
end

## Interactive prompts
function prompt_yn(question::String, default_yes::Bool = true)::Bool
    hint = default_yes ? "[Y/n]" : "[y/N]"
    print("  $question $hint: ")
    answer = strip(readline())
    isempty(answer) && return default_yes
    return lowercase(answer) in ("y", "yes")
end

function prompt_path(label::String)::Union{String,Nothing}
    print("  $label: ")
    p = strip(readline())
    isempty(p) ? nothing : p
end

## Download helpers
# Download `url` to `dest`.
function download_to(url::String, dest::String)
    @info "Downloading $(basename(url))..."
    Downloads.download(url, dest)
end

# Recursively check `dir` and return the first file named `filename`, or nothing.
function find_file_in_dir(dir::String, filename::String)::Union{String,Nothing}
    for (root, _dirs, files) in walkdir(dir)
        idx = findfirst(==(filename), files)
        idx !== nothing && return joinpath(root, files[idx])
    end
    nothing
end

# Reject the file unless it hashes to `expected`. A missing pin is a recorded
# absence of a checksum, not licence to dispense with one, so it aborts rather
# than install bytes nobody has vouched for. The offending file is deleted so that
# a failed run cannot leave a half-trusted artefact behind for the next one.
function verify_sha256(path::String, expected, source::String)
    expected === nothing && error(
        "No SHA256 is pinned for $source in $VERSIONS_FILE.\n" *
        "Record the checksum before installing; an unverifiable download is refused."
    )
    actual = bytes2hex(open(sha256, path))
    want   = lowercase(strip(string(expected)))
    if actual != want
        rm(path; force=true)
        error(
            "Checksum mismatch for $(basename(source)).\n" *
            "  expected: $want\n" *
            "  actual:   $actual\n" *
            "The download does not match its pin in $VERSIONS_FILE, so it is not the\n" *
            "artefact this project was tested against. Refusing to install it."
        )
    end
    @info "Verified SHA256 of $(basename(source))."
end

function download_verified(url::String, dest::String, expected)
    download_to(url, dest)
    verify_sha256(dest, expected, url)
    dest
end

## Tool download functions
# Unpack `tarball` in a scratch directory and move `binary` out of it into bin/.
# Unpacking away from bin/ is what keeps the result deterministic: a source tree
# left by an earlier version can otherwise be picked up in place of this one.
function extract_binary(tarball::String, binary::String)::String
    workdir = mktempdir()
    try
        run(`tar -xzf $tarball -C $workdir --warning=no-unknown-keyword`)
        found = find_file_in_dir(workdir, binary)
        found === nothing && error("$binary not found in $(basename(tarball)) after extraction.")
        dest = joinpath(BIN_DIR, binary)
        mv(found, dest; force=true)
        chmod(dest, 0o755)
        return dest
    finally
        rm(workdir; recursive=true, force=true)
    end
end

function download_pinned_binary(tool::String, binary::String)::String
    rec     = pinned_archive(tool)
    version = pinned_version(tool)
    @info "Installing $tool $version (pinned)..."

    tarball = joinpath(BIN_DIR, "$(binary)_download.tar.gz")
    try
        download_verified(rec["url"], tarball, get(rec, "sha256", nothing))
        return extract_binary(tarball, binary)
    finally
        rm(tarball; force=true)
    end
end

download_vsearch()::String = download_pinned_binary("vsearch", "vsearch")

function download_fastqc()::String
    rec     = pinned_archive("fastqc")
    version = pinned_version("fastqc")
    url     = string(rec["url"])

    zipfile = joinpath(BIN_DIR, "fastqc.zip")
    try
        download_to(url, zipfile)
    catch e
        rm(zipfile; force=true)
        error(
            "Failed to download FastQC v$version from $url\n" *
            "Babraham publish no release API, so this URL is pinned by hand in\n" *
            "$VERSIONS_FILE and may have moved. Download it manually from\n" *
            "https://www.bioinformatics.babraham.ac.uk/projects/fastqc/ and place the\n" *
            "fastqc binary in bin/.\n" *
            "Original error: $e"
        )
    end
    verify_sha256(zipfile, get(rec, "sha256", nothing), url)

    run(`unzip -q -o $zipfile -d $BIN_DIR`)
    rm(zipfile)

    bin = joinpath(BIN_DIR, "FastQC", "fastqc")
    isfile(bin) || error("fastqc not found after extraction. Expected at $bin")
    chmod(bin, 0o755)
    bin
end

function download_cdhit()::String
    version = pinned_version("cd_hit_est")

    pkg_cmd = package_install_cmd(["cd-hit"]; brew_pkg="cd-hit")
    if pkg_cmd !== nothing
        # A distribution package is whatever that distribution ships, which need not
        # be the pinned version. It is preferred anyway, because building cd-hit from
        # source needs a C++ toolchain that many machines lack; the version actually
        # obtained is recorded at preflight, where a discrepancy is visible.
        @info "Trying package manager install for cd-hit (expected v$version)..."
        try
            run(pkg_cmd)
            found = Sys.which("cd-hit-est")
            found !== nothing && return found
        catch
            @warn "Package manager install failed, falling back to source build."
        end
    end

    # Fallback: build from the pinned source tarball (upstream publish no precompiled
    # Linux binary).
    Sys.which("make") === nothing && error(
        "cd-hit could not be installed via package manager and 'make' is not available to build from source.\n" *
        "Install cd-hit manually and enter the path to cd-hit-est when prompted."
    )

    rec     = pinned_archive("cd_hit_est")
    tarball = joinpath(BIN_DIR, "cdhit_download.tar.gz")
    workdir = mktempdir()
    try
        @info "Downloading cd-hit v$version source and building from source..."
        download_verified(string(rec["url"]), tarball, get(rec, "sha256", nothing))
        run(`tar -xzf $tarball -C $workdir --warning=no-unknown-keyword`)

        src_dir = nothing
        for entry in readdir(workdir; join=true)
            isdir(entry) && startswith(basename(entry), "cd-hit") && (src_dir = entry; break)
        end
        src_dir === nothing && error("cd-hit source directory not found after extraction.")

        run(Cmd(`make -j$(Sys.CPU_THREADS)`; dir=src_dir))

        bin = joinpath(src_dir, "cd-hit-est")
        isfile(bin) || error("cd-hit-est binary not found after building. Check that a C++ compiler is installed.")

        dest = joinpath(BIN_DIR, "cd-hit-est")
        cp(bin, dest; force=true)
        chmod(dest, 0o755)
        return dest
    finally
        rm(tarball; force=true)
        rm(workdir; recursive=true, force=true)
    end
end

"""
Add the user's local bin directory to ENV["PATH"] so that Sys.which() and
subsequent Cmd calls can find freshly-installed scripts without restarting.
"""
function ensure_local_bin_on_path()
    local_bin = joinpath(homedir(), ".local", "bin")
    paths = split(get(ENV, "PATH", ""), ':')
    if local_bin ∉ paths
        ENV["PATH"] = local_bin * ":" * ENV["PATH"]
    end
end

function ensure_pipx()
    Sys.which("pipx") !== nothing && return  # already present

    @info "pipx not found - attempting to install it..."

    pkg_cmd = package_install_cmd(["pipx"]; brew_pkg="pipx", pacman_pkg="python-pipx", zypper_pkg="python3-pipx")
    if pkg_cmd !== nothing
        try
            run(pkg_cmd)
            run(`pipx ensurepath`)
            ensure_local_bin_on_path()
            Sys.which("pipx") !== nothing && return
        catch
            @warn "Package manager install of pipx failed."
        end
    end

    # Fallback: bootstrap pipx via pip/python3
    pip_cmd = nothing
    for candidate in (`pip3`, `pip`, `python3 -m pip`)
        try
            run(pipeline(`$candidate --version`; stdout=devnull, stderr=devnull))
            pip_cmd = candidate
            break
        catch
        end
    end

    if pip_cmd !== nothing
        try
            run(`$pip_cmd install --user pipx`)
            run(`python3 -m pipx ensurepath`)
            # Update PATH in the running process so Sys.which finds pipx
            ensure_local_bin_on_path()
            Sys.which("pipx") !== nothing && return
        catch
        end
    end

    @warn "Could not install pipx automatically. Python tools (cutadapt, multiqc) " *
          "may need to be installed manually."
end

function pipx_has_tool(name::String)::Bool
    Sys.which("pipx") === nothing && return false
    try
        output = read(`pipx list --short`, String)
        # Each line reads "<package> <version>", so only the first field is the name.
        for line in split(output, '\n')
            fields = split(strip(line))
            !isempty(fields) && fields[1] == name && return true
        end
        return false
    catch
        return false
    end
end

function install_python_tool(name::String)::String
    version = pinned_version(name)
    spec    = "$(name)==$(version)"

    # pipx (recommended on PEP 668 / Debian-managed systems)
    if Sys.which("pipx") !== nothing
        # There is no upgrade path, by design: `pipx upgrade` would walk the tool off
        # its pin. Where the tool is already present, --force reinstalls it at the
        # pinned version, which is also what makes --update idempotent rather than
        # a slow drift towards whatever PyPI published last.
        args = pipx_has_tool(name) ?
            ["pipx", "install", "--force", spec] :
            ["pipx", "install", spec]

        @info "Installing $spec via pipx..."
        run(Cmd(args))
        ensure_local_bin_on_path()
        found = find_in_path(name)
        found !== nothing && return found
        # pipx installs to ~/.local/bin by default
        local_bin = joinpath(homedir(), ".local", "bin", name)
        isfile(local_bin) && return local_bin
        @warn "Installed $name via pipx but could not locate the binary. Ensure ~/.local/bin is in PATH."
        return name
    end

    # Fallback to pip --user, then --break-system-packages if blocked
    pip_cmd = nothing
    for candidate in (`pip3`, `pip`, `python3 -m pip`)
        try
            run(pipeline(`$candidate --version`; stdout=devnull, stderr=devnull))
            pip_cmd = candidate
            break
        catch
        end
    end
    pip_cmd === nothing && error(
        "Neither pipx nor pip found. Install pipx (recommended) or Python 3 with pip."
    )

    @info "Installing $spec via pip..."
    success = try
        run(`$pip_cmd install --user $spec`)
        true
    catch
        false
    end

    if !success
        # Fallback 2 to PEP 668: externally-managed environment, try --break-system-packages
        @warn "pip --user blocked by system policy. Retrying with --break-system-packages..."
        run(`$pip_cmd install --user --break-system-packages $spec`)
    end

    ensure_local_bin_on_path()

    # Locate the installed binary
    found = find_in_path(name)
    found !== nothing && return found

    local_bin = joinpath(homedir(), ".local", "bin", name)
    isfile(local_bin) && return local_bin

    @warn "Installed $name but could not locate the binary. Ensure ~/.local/bin is in PATH."
    name
end

function download_swarm()::String
    # An already-present bin/swarm is honoured, but not under --update, whose whole
    # purpose is to re-assert the pin. Trusting it there would let a binary of
    # unknown provenance, predating the pins, survive every update indefinitely.
    bundled = joinpath(BIN_DIR, "swarm")
    if !UPDATE_MODE && isfile(bundled) && Sys.isexecutable(bundled)
        @info "Using bundled swarm binary at $bundled"
        return bundled
    end

    download_pinned_binary("swarm", "swarm")
end

function install_r_sysdeps()
    # System libraries required to compile Bioconductor / tidyverse packages from source.
    # Package names differ across distro families; each list maps to the same underlying
    # libraries (bzip2, xz, zlib, curl, openssl, libxml2, freetype, libpng, libjpeg,
    # libtiff, fontconfig, harfbuzz, fribidi, hdf5).

    apt_deps = [
        "pkg-config",
        "libbz2-dev", "liblzma-dev", "zlib1g-dev",
        "libcurl4-openssl-dev", "libssl-dev",
        "libxml2-dev",
        "libfreetype6-dev", "libpng-dev",
        "libjpeg-dev", "libtiff5-dev",
        "libfontconfig1-dev",
        "libharfbuzz-dev", "libfribidi-dev",
        "libhdf5-dev",
    ]

    dnf_deps = [
        "pkgconf-pkg-config",
        "bzip2-devel", "xz-devel", "zlib-devel",
        "libcurl-devel", "openssl-devel",
        "libxml2-devel",
        "freetype-devel", "libpng-devel",
        "libjpeg-turbo-devel", "libtiff-devel",
        "fontconfig-devel",
        "harfbuzz-devel", "fribidi-devel",
        "hdf5-devel",
    ]

    pacman_deps = [
        "pkgconf",
        "bzip2", "xz", "zlib",
        "curl", "openssl",
        "libxml2",
        "freetype2", "libpng",
        "libjpeg-turbo", "libtiff",
        "fontconfig",
        "harfbuzz", "fribidi",
        "hdf5",
    ]

    zypper_deps = [
        "pkg-config",
        "libbz2-devel", "xz-devel", "zlib-devel",
        "libcurl-devel", "libopenssl-devel",
        "libxml2-devel",
        "freetype2-devel", "libpng16-devel",
        "libjpeg8-devel", "libtiff-devel",
        "fontconfig-devel",
        "harfbuzz-devel", "fribidi-devel",
        "hdf5-devel",
    ]

    OS_TYPE != "linux" && return

    if Sys.which("apt-get") !== nothing
        _install_sysdeps_with(package_install_cmd(apt_deps; linux_manager=:apt_get), apt_deps, "apt-get")
    elseif Sys.which("dnf") !== nothing
        _install_sysdeps_with(package_install_cmd(dnf_deps; linux_manager=:dnf), dnf_deps, "dnf")
    elseif Sys.which("pacman") !== nothing
        _install_sysdeps_with(package_install_cmd(pacman_deps; linux_manager=:pacman), pacman_deps, "pacman")
    elseif Sys.which("zypper") !== nothing
        _install_sysdeps_with(package_install_cmd(zypper_deps; linux_manager=:zypper), zypper_deps, "zypper")
    else
        @warn "Could not detect a supported package manager (apt-get, dnf, pacman, zypper). " *
              "Some R packages may fail to compile. Install the development headers for: " *
              "bzip2, xz, zlib, curl, openssl, libxml2, freetype, libpng, libjpeg, " *
              "libtiff, fontconfig, harfbuzz, fribidi, hdf5"
    end
end

function _install_sysdeps_with(cmd::Union{Cmd,Nothing}, deps::Vector{String}, label::String)
    if cmd === nothing
        @info "Skipping automated $label install for R system dependencies because this session does not have root or passwordless sudo. " *
              "If compilation fails, install these packages manually:\n  " * join(deps, " ")
        return
    end
    @info "Installing R system library dependencies via $label..."
    try
        run(cmd)
    catch
        @warn "$label install of R system deps failed. " *
              "Some R packages may not compile; install these packages manually:\n  " * join(deps, " ")
    end
end

function install_r_packages(packages::Vector{String}; force_reinstall::Bool=false)
    pkgs_r  = join(["\"$p\"" for p in packages], ", ")
    force_r = force_reinstall ? "TRUE" : "FALSE"
    snippet = """
        # Ensure a user-writable library is first on the search path
        user_lib <- Sys.getenv("R_LIBS_USER",
                        unset = file.path(path.expand("~"), "R", "library"))
        dir.create(user_lib, recursive = TRUE, showWarnings = FALSE)
        .libPaths(c(user_lib, .libPaths()))

        if (!requireNamespace("BiocManager", quietly = TRUE))
            install.packages("BiocManager", repos = "https://cloud.r-project.org",
                             lib = user_lib)

        pkgs <- c($pkgs_r)

        if ($force_r) {
            message("Reinstalling all packages...")
            BiocManager::install(pkgs, ask = FALSE, force = TRUE, dependencies = NA)
        } else {
            broken <- pkgs[!sapply(pkgs, function(p) {
                tryCatch({ library(p, character.only = TRUE); TRUE },
                         error = function(e) FALSE)
            })]
            if (length(broken) > 0) {
                message("Installing/repairing: ", paste(broken, collapse = ", "))
                BiocManager::install(broken, ask = FALSE, dependencies = NA)
            } else {
                message("All R packages already installed and loadable.")
            }
        }

        # Final verification. Exit non-zero so Julia can detect failures.
        failed <- pkgs[!sapply(pkgs, function(p) {
            tryCatch({ library(p, character.only = TRUE); TRUE },
                     error = function(e) FALSE)
        })]
        if (length(failed) > 0) {
            message("ERROR: the following packages could not be loaded after install: ",
                    paste(failed, collapse = ", "))
            quit(status = 1)
        }
    """
    try
        run(`Rscript -e $snippet`)
        @info "R packages installed successfully."
    catch e
        @error "R package installation failed: $e"
        rethrow()
    end
end

## Per-tool resolution

# Resolves a single tool interactively. Returns the resolved path string, or nothing
# if the user chose to skip. When `install_fn` is provided, offers an auto-install
# option as the first choice.
function resolve_tool(
    key::String,
    display_name::String,
    existing_config::Dict,
    install_fn::Union{Function,Nothing} = nothing
)::Union{String,Nothing}
    bin = bin_name(key)
    heading_printed = false
    function show_heading()
        if !heading_printed
            println()
            println("  --- $display_name -------------------------------------------------")
            heading_printed = true
        end
    end

    # Check existing config (skip in update mode for managed installs)
    existing = get(existing_config, key, nothing)
    existing_path = existing isa Dict ? get(existing, "path", nothing) : nothing

    if existing_path !== nothing && !UPDATE_MODE
        if check_tool(string(existing_path))
            if MODIFY_MODE
                show_heading()
                println("  Configured path: $existing_path")
                prompt_yn("  Use this?") && return string(existing_path)
            else
                return string(existing_path)
            end
        else
            show_heading()
            println("  Configured path: $existing_path")
            println("  Warning: configured path does not appear to be callable.")
        end
    end

    # Check PATH
    path_result = find_in_path(bin)
    if path_result !== nothing
        show_heading()
        println("  Found in PATH:   $path_result")
        prompt_yn("  Use this?") && return path_result
    end

    # Build option list
    show_heading()
    options = String[]
    if install_fn !== nothing
        push!(options, "Install/download automatically to bin/")
    end
    push!(options, "Enter a path manually  (local: /path/to/$bin  or  remote: user@host:/path/to/$bin)")
    push!(options, "Skip  (configure later in config/tools.yml)")

    for (i, opt) in enumerate(options)
        println("  $i) $opt")
    end

    print("  Choice [1]: ")
    raw = strip(readline())
    choice = isempty(raw) ? 1 : something(tryparse(Int, raw), 1)

    if install_fn !== nothing
        if choice == 1
            try
                return install_fn()
            catch e
                @error "Auto-install failed: $e"
                println()
                println("  What would you like to do?")
                println("  1) Enter a path manually  (local: /path/to/$bin  or  remote: user@host:/path/to/$bin)")
                println("  2) Skip  (configure later in config/tools.yml)")
                print("  Choice [1]: ")
                raw2 = strip(readline())
                choice = isempty(raw2) ? 1 : something(tryparse(Int, raw2), 1)
                choice == 1 || return nothing
                return prompt_path("  Enter path")
            end
        end
        if choice == 2
            return prompt_path("  Enter path")
        end
        return nothing  # Skip
    else
        if choice == 1
            return prompt_path("  Enter path")
        end
        return nothing  # Skip
    end
end

## Sysimage creation
const SYSIMAGE_EXT  = Sys.isapple() ? ".dylib" : ".so"
const SYSIMAGE_PATH = joinpath(PROJECT_ROOT, "MetaManifold$(SYSIMAGE_EXT)")
const PRECOMPILE_EXEC_PATH = joinpath(PROJECT_ROOT, "precompile_exec.jl")

function build_sysimage()
    @info "Installing PackageCompiler..."
    Pkg.add("PackageCompiler")

    # Import after installation so it is available in this session
    @eval using PackageCompiler

    @info "Compiling sysimage - this may take several minutes...\n  Package: MetaManifold\n  Output:  $SYSIMAGE_PATH"

    kw = isfile(PRECOMPILE_EXEC_PATH) ?
        (; precompile_execution_file=[PRECOMPILE_EXEC_PATH]) : (;)

    PackageCompiler.create_sysimage(
        [:MetaManifold];
        sysimage_path = SYSIMAGE_PATH,
        project       = PROJECT_ROOT,
        kw...
    )

    @info "Sysimage written to $SYSIMAGE_PATH"
    println()
    println("Start the server with:")
    println("  bash start.sh")
end

## Preflight checks
"""Return true if the current process is running as root."""
has_root() = try; ccall(:geteuid, Cuint, ()) == 0; catch; false; end

"""Return true if sudo is available and can run non-interactively."""
function has_passwordless_sudo()::Bool
    Sys.which("sudo") === nothing && return false
    try
        run(pipeline(`sudo -n true`; stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

function package_install_cmd(
    pkgs::Vector{String};
    brew_pkg::Union{String,Nothing}=nothing,
    pacman_pkg::Union{String,Nothing}=nothing,
    zypper_pkg::Union{String,Nothing}=nothing,
    linux_manager::Union{Symbol,Nothing}=nothing,
)
    if OS_TYPE == "macos"
        if Sys.which("brew") !== nothing
            mac_pkgs = brew_pkg === nothing ? pkgs : [brew_pkg]
            return Cmd(vcat(["brew", "install"], mac_pkgs))
        end
        return nothing
    end

    prefix = if has_root()
        String[]
    elseif has_passwordless_sudo()
        ["sudo"]
    else
        return nothing
    end
    manager = linux_manager
    if manager === nothing
        manager = Sys.which("apt-get") !== nothing ? :apt_get :
                  Sys.which("dnf") !== nothing ? :dnf :
                  Sys.which("pacman") !== nothing ? :pacman :
                  Sys.which("zypper") !== nothing ? :zypper :
                  nothing
    end
    manager === nothing && return nothing

    if manager == :apt_get
        return Cmd(vcat(prefix, ["apt-get", "install", "-y"], pkgs))
    elseif manager == :dnf
        return Cmd(vcat(prefix, ["dnf", "install", "-y"], pkgs))
    elseif manager == :pacman
        pacman_pkgs = pacman_pkg === nothing ? pkgs : [pacman_pkg]
        return Cmd(vcat(prefix, ["pacman", "-S", "--needed", "--noconfirm"], pacman_pkgs))
    elseif manager == :zypper
        zypper_pkgs = zypper_pkg === nothing ? pkgs : [zypper_pkg]
        return Cmd(vcat(prefix, ["zypper", "install", "-y"], zypper_pkgs))
    end

    nothing
end

## Main
function main()
    if UPDATE_MODE || MODIFY_MODE
        println()
        println("+-------------------------------------------+")
        println("|  MetaManifold - Install Script            |")
        println("+-------------------------------------------+")
        UPDATE_MODE && println("  Mode: UPDATE")
        MODIFY_MODE && println("  Mode: MODIFY")
        println()
    end

    # State the pins up front. An installer that says nothing about the versions it
    # is about to fetch leaves the operator no way to notice a wrong one.
    println("  Pinned tool versions ($VERSIONS_FILE):")
    for key in sort(collect(keys(PINS["tools"])))
        println("    $(rpad(bin_name(key), 12)) $(pinned_version(key))")
    end
    println()

    config = load_tools_config()
    resolved = Dict{String,Any}()

    # Ensure pipx/pip is available before resolving Python-based tools
    ensure_pipx()

    # cutadapt
    path = resolve_tool("cutadapt", "cutadapt", config,
        () -> install_python_tool("cutadapt"))
    resolved["cutadapt"] = Dict("path" => path)

    # fastqc
    path = resolve_tool("fastqc", "FastQC", config,
        () -> download_fastqc())
    resolved["fastqc"] = Dict("path" => path)

    # multiqc
    path = resolve_tool("multiqc", "MultiQC", config,
        () -> install_python_tool("multiqc"))
    resolved["multiqc"] = Dict("path" => path)

    # vsearch
    path = resolve_tool("vsearch", "vsearch", config,
        () -> download_vsearch())
    resolved["vsearch"] = Dict("path" => path)

    # cd-hit-est
    path = resolve_tool("cd_hit_est", "cd-hit-est", config,
        () -> download_cdhit())
    resolved["cd_hit_est"] = Dict("path" => path)

    # swarm
    path = resolve_tool("swarm", "swarm", config,
        () -> download_swarm())
    resolved["swarm"] = Dict("path" => path)

    # R packages
    r_packages = ["dada2", "vegan"]
    should_install_r = UPDATE_MODE || (MODIFY_MODE && prompt_yn("  Install/check R packages (dada2, vegan)?"))
    if should_install_r
        println()
        println("  --- R packages -----------------------------------------------------")
        install_r_sysdeps()
        force_reinstall_r = UPDATE_MODE &&
            prompt_yn("  Reinstall all R packages (dada2, vegan)?", false)
        install_r_packages(r_packages; force_reinstall=force_reinstall_r)
    end

    # Write config
    write_tools_config(resolved)

    # Create a data directory
    mkpath("data")

    # Sysimage
    if SYSIMAGE_MODE
        println()
        println("  --- Julia sysimage -------------------------------------------------")
        build_sysimage()
    end

    println()
    println("Installation complete.")
    println()
    println("To set remote SSH paths or adjust any tool locations, edit:")
    println("  $TOOLS_CONFIG")
    println()
    println("Example remote path (SSH):")
    println("  vsearch:")
    println("    path: \"user@bioserver:/home/user/software/vsearch\"")
end

RUNNING_AS_SCRIPT && main()
