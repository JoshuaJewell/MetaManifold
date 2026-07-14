module ProjectSetup

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export new_project

    using YAML
    using ..PipelineTypes
    using ..PipelineLog: pipeline_log

    const _PIPELINE_YML_HEADER = """
# Pipeline configuration overrides
# Add only the sections/keys you want to change relative to the parent level.
# Omitted settings are inherited from the nearest ancestor or from
# config/defaults/pipeline.yml (which lists all available options).
# This file is merged at runtime; delete it to inherit everything from above.
"""

    const _STUDY_PIPELINE_YML = """
# Pipeline configuration - STUDY LEVEL
#
# Settings written here are the default for every run under this study.
# Place settings that define the study as a whole here: which primer pair
# was used, the target amplicon length range, the taxonomy database, etc.
#
# Leave a key out entirely to inherit the global (config/pipeline.yml)
# settings. Only write what you deliberately want to change.
#
# Any group- or run-level pipeline.yml beneath this directory can override
# these values further.
"""

    const _GROUP_PIPELINE_YML = """
# Pipeline configuration - GROUP LEVEL
#
# Settings written here apply to all runs in this sub-directory and take
# precedence over the study-level file above.
#
# Use this when a subset of runs share settings that differ from the rest
# of the study (e.g. a different sequencing batch or primer set).
#
# Leave a key out entirely to inherit from the study level. Only write
# what you deliberately want to change.
"""

    const _RUN_PIPELINE_YML = """
# Pipeline configuration - RUN LEVEL
#
# Settings written here apply to this single run only and take precedence
# over every level above.
#
# Leave a key out entirely to inherit from the group or study level. Only
# write what you deliberately want to change.
#
# The fully-merged result of every cascade level is written to
# projects/{study}/{run}/run_config.yml at runtime. That file is the
# authoritative record of exactly what configuration was used.
"""

    function _create_if_absent(path::String, content::String)
        if !isfile(path)
            write(path, content)
            @info "Created: $path"
        end
    end

    """
        new_project(name; data_dir, projects_dir, config_dir)

    Bootstrap a project for the study named `name`.

    Pipeline configuration stubs (`pipeline.yml`) are created inside the data
    tree (`data_dir/{name}/`) so that inputs and their settings are co-located.
    Edit those files before (re-)running the pipeline. Omitted keys inherit from
    the nearest ancestor, falling back to `config/defaults/pipeline.yml`.

    Output directories are created under `projects_dir/{name}/` mirroring the
    data layout. They contain only pipeline outputs and the auto-generated
    `run_config.yml` (the fully-merged configuration actually used).

    `databases.yml`, `tools.yml`, and `primers.yml` are copied from
    `config/defaults/` on first run (edit them in place; they are not cascaded).

    Re-running `new_project` never overwrites existing files.

    Returns a `Vector{ProjectCtx}`, one per leaf run.
    """
    function new_project(name::String;
                         data_dir::String     = "./data",
                         projects_dir::String = "./projects",
                         config_dir::String   = "./config")

        defaults_dir = joinpath(config_dir, "defaults")
        root_data    = joinpath(data_dir, name)
        root_project = joinpath(projects_dir, name)

        isdir(root_data) || error("Data directory not found: $root_data")

        # Standalone configs (not cascade-merged) - copy from defaults if missing
        for fname in ("databases.yml", "tools.yml", "primers.yml", "composition.yml")
            dst = joinpath(config_dir, fname)
            if !isfile(dst)
                src = joinpath(defaults_dir, fname)
                isfile(src) || error("Default template not found: $src")
                cp(src, dst)
                @info "Created: $dst"
            end
        end

        _create_if_absent(joinpath(config_dir, "pipeline.yml"), _PIPELINE_YML_HEADER)

        ## Leaf discovery with pool_children support
        #
        # Walk the data tree depth-first. A directory is a "pooled group" if its
        # pipeline.yml contains `pool_children: true`. When encountered, that
        # directory becomes the leaf and its children are collected as data_dirs
        # (they are NOT independent runs). Otherwise, the traditional rule applies:
        # a directory is a leaf if it directly contains .fastq.gz files.

        # Returns (leaf_relpaths, pooled_children) where pooled_children maps
        # a leaf relpath to the list of child data directories it pools.
        leaf_relpaths    = String[]
        pooled_children  = Dict{String, Vector{String}}()  # relpath => [abs child dirs]
        pooled_ancestors = Set{String}()  # absolute paths of dirs consumed by a pool

        # First pass: identify pooled groups (top-down so parents win over children).
        for (dirpath, subdirs, _) in walkdir(root_data; follow_symlinks=true)
            dirpath in pooled_ancestors && continue
            yml = joinpath(dirpath, "pipeline.yml")
            if isfile(yml)
                cfg = YAML.load_file(yml)
                if cfg isa Dict && get(cfg, "pool_children", false) == true
                    rp = relpath(dirpath, root_data)
                    rp = rp == "." ? "." : rp
                    # Collect every child directory that contains FASTQs.
                    child_dirs = String[]
                    for (child, _, child_files) in walkdir(dirpath; follow_symlinks=true)
                        child == dirpath && continue
                        if any(f -> endswith(f, ".fastq.gz"), child_files)
                            push!(child_dirs, child)
                            push!(pooled_ancestors, child)
                        end
                    end
                    if !isempty(child_dirs)
                        push!(leaf_relpaths, rp)
                        pooled_children[rp] = child_dirs
                        # Mark the pooled dir itself and all descendants as consumed.
                        push!(pooled_ancestors, dirpath)
                        for sd in subdirs
                            push!(pooled_ancestors, joinpath(dirpath, sd))
                        end
                    end
                end
            end
        end

        # Second pass: normal leaf detection for non-pooled directories.
        for (dirpath, _, files) in walkdir(root_data; follow_symlinks=true)
            dirpath in pooled_ancestors && continue
            if any(f -> endswith(f, ".fastq.gz"), files)
                rp = relpath(dirpath, root_data)
                rp in leaf_relpaths || push!(leaf_relpaths, rp)
            end
        end

        isempty(leaf_relpaths) && error("No .fastq.gz files found under $root_data")

        leaf_data_dirs = Set{String}()
        for rp in leaf_relpaths
            push!(leaf_data_dirs, rp == "." ? root_data : joinpath(root_data, rp))
            # For pooled groups, the children are also "leaf-like" for the purpose
            # of knowing which dirs already contain data (don't stamp as GROUP).
            for child in get(pooled_children, rp, String[])
                push!(leaf_data_dirs, child)
            end
        end

        all_data_dirs = Set{String}([root_data])
        for rp in leaf_relpaths
            rp == "." && continue
            parts = splitpath(rp)
            for i in 1:length(parts)
                push!(all_data_dirs, joinpath(root_data, parts[1:i]...))
            end
        end
        # Include child directories of pooled groups (they still need pipeline.yml stubs).
        for children in values(pooled_children)
            for child in children
                push!(all_data_dirs, child)
            end
        end

        # Top-down so parents exist first
        sorted_data_dirs = sort(collect(all_data_dirs), by = d -> length(splitpath(d)))
        for dir in sorted_data_dirs
            yml_content = if dir in leaf_data_dirs
                _RUN_PIPELINE_YML
            elseif dir == root_data
                _STUDY_PIPELINE_YML
            else
                _GROUP_PIPELINE_YML
            end
            _create_if_absent(joinpath(dir, "pipeline.yml"), yml_content)
        end

        for rp in leaf_relpaths
            proj_dir = rp == "." ? root_project : joinpath(root_project, rp)
            mkpath(proj_dir)
        end

        projects = ProjectCtx[]
        for rp in leaf_relpaths
            proj_dir  = rp == "." ? root_project : joinpath(root_project, rp)
            fastq_dir = rp == "." ? root_data    : joinpath(root_data,    rp)
            data_dirs = if haskey(pooled_children, rp)
                pooled_children[rp]
            else
                [fastq_dir]
            end
            ctx = ProjectCtx(proj_dir, config_dir, fastq_dir, root_project, root_data, data_dirs)
            pipeline_log(ctx, "Project initialised" *
                         (length(data_dirs) > 1 ? " (pooling $(length(data_dirs)) sub-groups)" : ""))
            push!(projects, ctx)
        end
        @info "$(length(projects)) project(s) ready under $root_project"
        return projects
    end

end
