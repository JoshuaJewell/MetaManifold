#!/usr/bin/env bash
#
# Bootstrap installer for MetabarcodingPipeline
#
# Checks for Julia and R, installs Julia via juliaup if missing,
# then hands off to install.jl for all further dependency setup.
#
# Usage:
#   bash install.sh [--update] [--modify] [--sysimage]
#
# Options:
#   --update    Abort any in-progress merge, sync tracked files to origin/main,
#               clean generated build artifacts, then re-assert the pinned tool
#               versions in bin/ (see config/defaults/tool_versions.yml). This
#               re-fetches the pins; it does not advance them.
#   --modify    Revisit configured tool paths instead of silently reusing them
#   --sysimage  Pass through to install.jl to build the Julia sysimage

set -euo pipefail

UPDATE_MODE=false
for arg in "$@"; do
    if [ "$arg" = "--update" ]; then
        UPDATE_MODE=true
        break
    fi
done

# OS detection

OS="$(uname -s)"
case "$OS" in
    Linux*)  OS_TYPE="Linux"  ;;
    Darwin*) OS_TYPE="macOS"  ;;
    *)
        echo "Unsupported OS: $OS"
        echo "This installer supports Linux and macOS only."
        exit 1
        ;;
esac

echo "Detected OS: $OS_TYPE"
echo ""

update_checkout() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "--update requested, but this directory is not a Git worktree."
        echo "Skipping checkout sync."
        echo ""
        return
    fi

    if ! git remote get-url origin >/dev/null 2>&1; then
        echo "--update requested, but no 'origin' remote is configured."
        echo "Skipping checkout sync."
        echo ""
        return
    fi

    echo "Syncing checkout to origin/main..."
    git merge --abort >/dev/null 2>&1 || true
    git fetch origin
    git reset --hard origin/main
    echo ""
}

if [ "$UPDATE_MODE" = true ]; then
    update_checkout
fi

# Julia check and install

if command -v julia &>/dev/null; then
    echo "Found Julia: $(julia --version)"
else
    echo "Julia not found. Installing via juliaup..."
    curl -fsSL https://install.julialang.org | sh -s -- --yes

    # juliaup installs to ~/.juliaup; source the env file if present
    if [ -f "$HOME/.juliaup/env" ]; then
        # shellcheck disable=SC1091
        source "$HOME/.juliaup/env"
    fi
    export PATH="$HOME/.juliaup/bin:$PATH"

    if command -v julia &>/dev/null; then
        echo "Julia installed: $(julia --version)"
    else
        echo ""
        echo "Julia was installed but is not yet in PATH."
        echo "Please open a new terminal and re-run this script, or install Julia"
        echo "manually from https://julialang.org/downloads/ and try again."
        exit 1
    fi
fi

# R check and politely ask user to do it for us

if command -v Rscript &>/dev/null; then
    echo "Found R:     $(Rscript --version 2>&1 | head -1)"
else
    echo ""
    echo "R is not installed. Please install R for your system and re-run this script."
    echo ""
    if [ "$OS_TYPE" = "Linux" ]; then
        echo "  Ubuntu/Debian:  https://cran.r-project.org/bin/linux/ubuntu/"
        echo "  Fedora/RHEL:    https://cran.r-project.org/bin/linux/fedora/"
        echo "  Quick install:  sudo apt install r-base   (Debian/Ubuntu)"
    elif [ "$OS_TYPE" = "macOS" ]; then
        echo "  macOS pkg:      https://cran.r-project.org/bin/macosx/"
        echo "  Homebrew:       brew install r"
    fi
    echo ""
    exit 1
fi

# Dependency installs by Julia

echo ""
echo "Running install.jl..."
echo ""
julia --project=. install.jl "$@"
