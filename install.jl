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
#   --update    Re-check tool versions and update managed binaries in bin/
#   --modify    Revisit configured tool paths instead of silently reusing them
#   --sysimage  After installation, compile a sysimage of all Julia deps to
#               speed up subsequent startup. Output: MetaManifold.so (.dylib on macOS)
#               Use with: julia --sysimage MetaManifold.so --project=. ...

using Pkg
@info "Installing Julia package dependencies..."
Pkg.instantiate()

using YAML
import Downloads

## Instantiate
const UPDATE_MODE   = "--update"   in ARGS
const MODIFY_MODE   = "--modify"   in ARGS
const SYSIMAGE_MODE = "--sysimage" in ARGS
const PROJECT_ROOT  = @__DIR__
const BIN_DIR       = joinpath(PROJECT_ROOT, "bin")
const CONFIG_DIR    = joinpath(PROJECT_ROOT, "config")
const TOOLS_CONFIG  = joinpath(CONFIG_DIR, "tools.yml")

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
# Fetch URL content as a String. Returns nothing on failure.
function fetch_string(url::String)::Union{String,Nothing}
    try
        buf = IOBuffer()
        Downloads.download(url, buf; headers=["User-Agent" => "MetaManifold-installer"])
        String(take!(buf))
    catch e
        @warn "Could not fetch $url: $e"
        nothing
    end
end

# Return the first capture group of `pattern` in `s`, or nothing.
function first_match(pattern::Regex, s::String)::Union{String,Nothing}
    m = match(pattern, s)
    m === nothing ? nothing : m[1]
end

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

## Tool download functions
function download_vsearch()::String
    @info "Fetching latest vsearch release info from GitHub..."
    json = fetch_string("https://api.github.com/repos/torognes/vsearch/releases/latest")
    json === nothing && error("Cannot reach GitHub API. Check your internet connection.")

    # Find a download URL matching OS and architecture
    pattern = Regex(
        "\"browser_download_url\":\\s*\"(https://[^\"]*vsearch[^\"]*$(OS_TYPE)[^\"]*$(ARCH_STR)[^\"]*.tar.gz)\""
    )
    url = first_match(pattern, json)

    # Fallback to any tar.gz for this OS
    if url === nothing
        url = first_match(
            Regex("\"browser_download_url\":\\s*\"(https://[^\"]*vsearch[^\"]*$(OS_TYPE)[^\"]*.tar.gz)\""),
            json
        )
    end

    url === nothing && error(
        "No vsearch binary found for $OS_TYPE/$ARCH_STR in the latest release.\n" *
        "Check https://github.com/torognes/vsearch/releases for available builds."
    )

    tarball = joinpath(BIN_DIR, "vsearch_download.tar.gz")
    download_to(url, tarball)
    run(`tar -xzf $tarball -C $BIN_DIR --warning=no-unknown-keyword`)
    rm(tarball)

    bin = find_file_in_dir(BIN_DIR, "vsearch")
    bin === nothing && error("vsearch binary not found after extraction.")

    dest = joinpath(BIN_DIR, "vsearch")
    bin != dest && mv(bin, dest; force=true)
    chmod(dest, 0o755)
    dest
end


function download_fastqc()::String
    # Pin to a known-good version. Babraham doesn't provide a releases API,
    # so we can't auto-detect the latest. Update this version periodically.
    version = "0.12.1"
    url = "https://www.bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v$(version).zip"

    zipfile = joinpath(BIN_DIR, "fastqc.zip")
    try
        download_to(url, zipfile)
    catch e
        error(
            "Failed to download FastQC v$version - the URL may have changed.\n" *
            "Download manually from https://www.bioinformatics.babraham.ac.uk/projects/fastqc/\n" *
            "and place the fastqc binary in bin/.\n" *
            "Original error: $e"
        )
    end
    run(`unzip -q -o $zipfile -d $BIN_DIR`)
    rm(zipfile)

    bin = joinpath(BIN_DIR, "FastQC", "fastqc")
    isfile(bin) || error("fastqc not found after extraction. Expected at $bin")
    chmod(bin, 0o755)
    bin
end

function download_cdhit()::String
    pkg_cmd = package_install_cmd(["cd-hit"]; brew_pkg="cd-hit")
    if pkg_cmd !== nothing
        @info "Trying package manager install for cd-hit..."
        try
            run(pkg_cmd)
            found = Sys.which("cd-hit-est")
            found !== nothing && return found
        catch
            @warn "Package manager install failed, falling back to source build."
        end
    end

    # Fallback: build from source tarball (no precompiled Linux binary on GitHub).
    Sys.which("make") === nothing && error(
        "cd-hit could not be installed via package manager and 'make' is not available to build from source.\n" *
        "Install cd-hit manually and enter the path to cd-hit-est when prompted."
    )

    url = "https://github.com/weizhongli/cdhit/releases/download/V4.8.1/cd-hit-v4.8.1-2019-0228.tar.gz"
    @info "Downloading cd-hit v4.8.1 source and building from source..."
    tarball = joinpath(BIN_DIR, "cdhit_download.tar.gz")
    download_to(url, tarball)
    run(`tar -xzf $tarball -C $BIN_DIR --warning=no-unknown-keyword`)
    rm(tarball)

    # Find the extracted source directory
    src_dir = nothing
    for entry in readdir(BIN_DIR; join=true)
        isdir(entry) && startswith(basename(entry), "cd-hit") && (src_dir = entry; break)
    end
    src_dir === nothing && error("cd-hit source directory not found after extraction.")

    run(Cmd(`make -j$(Sys.CPU_THREADS)`; dir=src_dir))

    bin = joinpath(src_dir, "cd-hit-est")
    isfile(bin) || error("cd-hit-est binary not found after building. Check that a C++ compiler is installed.")

    dest = joinpath(BIN_DIR, "cd-hit-est")
    cp(bin, dest; force=true)
    chmod(dest, 0o755)
    dest
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
        return any(strip(line) == name for line in split(output, '\n'))
    catch
        return false
    end
end

function install_python_tool(name::String)::String
    # pipx (recommended on PEP 668 / Debian-managed systems)
    if Sys.which("pipx") !== nothing
        action = pipx_has_tool(name) ? "upgrade" : "install"

        @info "$(uppercasefirst(action))ing $name via pipx..."
        run(Cmd(["pipx", action, name]))
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

    @info "Installing $name via pip..."
    success = try
        run(`$pip_cmd install --user $name`)
        true
    catch
        false
    end

    if !success
        # Fallback 2 to PEP 668: externally-managed environment, try --break-system-packages
        @warn "pip --user blocked by system policy. Retrying with --break-system-packages..."
        run(`$pip_cmd install --user --break-system-packages $name`)
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
    # Check for bundled binary first.
    bundled = joinpath(BIN_DIR, "swarm")
    if isfile(bundled) && Sys.isexecutable(bundled)
        @info "Using bundled swarm binary at $bundled"
        return bundled
    end

    @info "Fetching latest swarm release info from GitHub..."
    json = fetch_string("https://api.github.com/repos/torognes/swarm/releases/latest")
    json === nothing && error("Cannot reach GitHub API. Check your internet connection.")

    # Match e.g. swarm-3.1.6-linux-x86_64
    os_tag   = OS_TYPE == "linux" ? "linux" : "macos"
    arch_tag = ARCH_STR
    pattern  = Regex(
        "\"browser_download_url\":\\s*\"(https://[^\"]*swarm[^\"]*$(os_tag)[^\"]*$(arch_tag)[^\"]*)\""
    )
    url = first_match(pattern, json)

    # Fallback: any asset for this OS
    if url === nothing
        url = first_match(
            Regex("\"browser_download_url\":\\s*\"(https://[^\"]*swarm[^\"]*$(os_tag)[^\"]*)\""),
            json
        )
    end

    url === nothing && error(
        "No swarm binary found for $OS_TYPE/$ARCH_STR in the latest GitHub release.\n" *
        "Download manually from https://github.com/torognes/swarm/releases and place at bin/swarm."
    )

    tarball = joinpath(BIN_DIR, "swarm_download.tar.gz")
    download_to(url, tarball)
    run(`tar -xzf $tarball -C $BIN_DIR --warning=no-unknown-keyword`)
    rm(tarball)

    bin = find_file_in_dir(BIN_DIR, "swarm")
    bin === nothing && error("swarm binary not found after extraction.")

    dest = joinpath(BIN_DIR, "swarm")
    bin != dest && mv(bin, dest; force=true)
    chmod(dest, 0o755)
    dest
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

main()
