module Config

# Hierarchical config cascade and per-section content-hash helpers.
#
# Config cascade (global -> study -> group(s) -> run):
#   config/defaults/pipeline.yml     <- full defaults (source of truth)
#   config/pipeline.yml              <- machine-level overrides
#   data/{study}/pipeline.yml        <- study-level overrides
#   ...intermediate dirs...
#   data/{study}/{run}/pipeline.yml  <- run-level overrides
#
# Pipeline configs live alongside the input data so that inputs are together
# in data/ and outputs remain isolated in projects/.
#
# Each override file contains only intentional changes; omitted keys are
# inherited from the nearest ancestor. At the start of each run, all levels
# are deep-merged into a single Dict and written to:
#   projects/{study}/{group}/{run}/run_config.yml
#
# Stage skip guards hash the relevant YAML section from run_config.yml so
# that any change at any level - global, study, or run - correctly
# invalidates downstream checkpoints.
#
# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

export _section_stale, _write_section_hash, _stale_keys,
       load_merged_config, write_run_config, stage_sections,
       DEFAULT_SEED

    using SHA, YAML
    using ..PipelineTypes

    const DEFAULT_SEED = 123

    ## Pipeline stage sections
    # Maps each stage to the config sections whose change should invalidate it.
    const _STAGE_SECTIONS = Dict(
        :fastqc_multiqc => ["fastqc", "multiqc"],
        :cutadapt => ["seed", "subsample_n", "cutadapt"],
        :dada2_filter_trim => ["dada2.file_patterns", "dada2.filter_trim"],
        :dada2_learn_errors => ["seed", "dada2.dada"],
        :dada2_denoise => ["seed", "dada2.dada", "dada2.merge"],
        :dada2_filter_length => ["dada2.asv"],
        :dada2_chimera_removal => ["dada2.asv", "dada2.output"],
        :dada2_assign_taxonomy => ["dada2.taxonomy", "dada2.output"],
        :cdhit => ["cdhit"],
        :swarm => ["swarm"],
        :vsearch => ["vsearch"],
        :merge_taxa => ["merge_taxa", "vsearch.enabled", "swarm.enabled", "dada2.taxonomy.enabled"],
    )

    function stage_sections(name::Symbol)::String
        sections = get(_STAGE_SECTIONS, name, nothing)
        isnothing(sections) && error("No pipeline stage named :$name")
        join(sections, ",")
    end

    ## Deep merge
    # Recursively merge `patch` into `base`. Dict values are merged recursively;
    # all other types (including Arrays) are replaced by the patch value.
    function _deep_merge(base::Dict, patch::Dict)
        result = copy(base)
        for (k, v) in patch
            result[k] = (haskey(result, k) && result[k] isa Dict && v isa Dict) ?
                        _deep_merge(result[k], v) : v
        end
        return result
    end

    ## Cascade path discovery
    # Return the ordered list of pipeline.yml paths participating in the cascade,
    # from least specific (defaults) to most specific (leaf project dir).
    function _cascade_paths(config_dir::String, study_dir::String, project_dir::String)
        paths = String[
            joinpath(config_dir, "defaults", "pipeline.yml"),
            joinpath(config_dir, "pipeline.yml"),
        ]

        study_norm   = normpath(abspath(study_dir))
        project_norm = normpath(abspath(project_dir))

        if study_norm == project_norm
            push!(paths, joinpath(project_norm, "pipeline.yml"))
        else
            rel   = relpath(project_norm, study_norm)
            parts = splitpath(rel)
            current = study_norm
            push!(paths, joinpath(current, "pipeline.yml"))
            for part in parts
                current = joinpath(current, part)
                push!(paths, joinpath(current, "pipeline.yml"))
            end
        end

        return paths
    end

    ## Config loading
    # Merge all config levels in `paths` (ordered global -> specific).
    # paths[1] must exist (the defaults file). Subsequent files are optional;
    # missing files and files that parse as nothing/empty are skipped.
    function load_merged_config(paths::Vector{String})
        isfile(paths[1]) || error("Default config not found: $(paths[1])")
        base = something(YAML.load_file(paths[1]), Dict())
        base isa Dict || (base = Dict())
        for path in paths[2:end]
            isfile(path) || continue
            patch = YAML.load_file(path)
            isnothing(patch) && continue
            patch isa Dict  || continue
            isempty(patch)  && continue
            base = _deep_merge(base, patch)
        end
        return base
    end

    load_merged_config(config_dir::String, study_dir::String, project_dir::String) =
        load_merged_config(_cascade_paths(config_dir, study_dir, project_dir))

    load_merged_config(project::ProjectCtx) =
        load_merged_config(project.config_dir, project.data_study_dir, project.data_dir)

    ## run_config.yml
    # Merge all cascade levels and write the result to {project.dir}/run_config.yml.
    # Regenerates only when a source file is newer than the existing run_config.yml.
    # Returns the path to run_config.yml.
    function write_run_config(project::ProjectCtx)
        run_config_path = joinpath(project.dir, "run_config.yml")
        primers_path    = joinpath(project.config_dir, "primers.yml")
        paths = _cascade_paths(project.config_dir, project.data_study_dir, project.data_dir)
        source_paths = isfile(primers_path) ? vcat(paths, primers_path) : paths
        if !isfile(run_config_path) ||
           any(p -> isfile(p) && mtime(p) >= mtime(run_config_path), source_paths)
            merged = load_merged_config(paths)
            if isfile(primers_path)
                primers = YAML.load_file(primers_path)
                isnothing(primers) || (merged["primers"] = primers)
            end
            open(run_config_path, "w") do io
                print(io, YAML.write(merged))
            end
        end
        return run_config_path
    end

    ## Section content hashes
    # Produce a stable, canonical string from a YAML-loaded value.
    # Dicts are sorted by key so insertion-order differences do not affect the hash.
    function _canonical(x)::String
        if x isa AbstractDict
            pairs_sorted = sort([(string(k), _canonical(v)) for (k, v) in x]; by = p -> p[1])
            return "{" * join(["$(p[1]):$(p[2])" for p in pairs_sorted], ",") * "}"
        elseif x isa AbstractVector
            return "[" * join(map(_canonical, x), ",") * "]"
        elseif isnothing(x)
            return "null"
        else
            return string(x)
        end
    end

    # Recursively collect all leaf (non-Dict) values into `out` as dotted-key => canonical-string pairs.
    function _collect_leaf_values!(out::Dict{String,String}, prefix::AbstractString, val)
        if val isa Dict
            for (k, v) in val
                _collect_leaf_values!(out, prefix == "" ? string(k) : "$prefix.$k", v)
            end
        else
            out[prefix] = _canonical(val)
        end
    end

    # Walk a dotted key path ("dada2.filter_trim") into a nested Dict.
    # Returns nothing if any key is missing or a non-Dict is encountered mid-path.
    function _get_nested(cfg, path::AbstractString)
        val = cfg
        for k in split(path, ".")
            val isa Dict || return nothing
            val = get(val, k, nothing)
            isnothing(val) && return nothing
        end
        return val
    end

    # Section can be a dotted path ("dada2.filter_trim") or a comma-separated
    # list of dotted paths ("dada2.dada,dada2.merge") whose canonical strings
    # are joined before hashing.
    function _section_hash(config_path::String, section::String)::String
        cfg = YAML.load_file(config_path)
        cfg isa Dict || return bytes2hex(sha256(""))
        combined = join([_canonical(_get_nested(cfg, strip(s)))
                         for s in split(section, ",")], "|")
        bytes2hex(sha256(combined))
    end

    """
        _section_stale(config_path, section, hash_file) -> Bool

    Return `true` if the named section of `config_path` has changed since
    `hash_file` was last written, or if `hash_file` does not yet exist.
    Pass `run_config.yml` as `config_path` to hash the fully-merged section.
    """
    function _section_stale(config_path::String, section::String, hash_file::String)::Bool
        !isfile(hash_file) && return true
        stored = strip(read(hash_file, String))
        return _section_hash(config_path, section) != stored
    end

    """
        _write_section_hash(config_path, section, hash_file)

    Write the current SHA-256 hash of the named section to `hash_file`.
    Call this after a stage completes successfully.
    """
    function _write_section_hash(config_path::String, section::String, hash_file::String)
        write(hash_file, _section_hash(config_path, section))
        _write_section_values(config_path, section, hash_file)
    end

    """
        _stale_keys(config_path, section, hash_file) -> Vector{String}

    If the section is stale, return the individual dotted config keys that
    changed compared to the snapshot stored in `hash_file.values`.

    When the stage last ran, `_write_section_hash` stores the hash; we also
    store a companion `.values` file with the canonical per-key values. If that
    file is missing (e.g. older run), we fall back to returning the section
    names only.
    """
    function _stale_keys(config_path::String, section::String, hash_file::String)::Vector{String}
        cfg = YAML.load_file(config_path)
        cfg isa Dict || return String[]

        values_file = hash_file * ".values"
        sections = [strip(s) for s in split(section, ",")]

        # Collect current leaf keys (recursive)
        current = Dict{String,String}()
        for sec in sections
            val = _get_nested(cfg, sec)
            isnothing(val) && continue
            _collect_leaf_values!(current, sec, val)
        end

        # Read stored values from companion file
        if isfile(values_file)
            stored = Dict{String,String}()
            for line in eachline(values_file)
                idx = findfirst('=', line)
                isnothing(idx) && continue
                stored[line[1:idx-1]] = line[idx+1:end]
            end
            # Diff: keys present in current but not stored, or with different values
            changed = String[]
            for (k, v) in current
                if !haskey(stored, k) || stored[k] != v
                    push!(changed, k)
                end
            end
            # Keys removed in current config
            for k in keys(stored)
                haskey(current, k) || push!(changed, k)
            end
            return sort(changed)
        else
            # No companion file - return section names as fallback
            return sections
        end
    end

    # Extend _write_section_hash to also write companion values file
    function _write_section_values(config_path::String, section::String, hash_file::String)
        cfg = YAML.load_file(config_path)
        cfg isa Dict || return
        sections = [strip(s) for s in split(section, ",")]
        values_file = hash_file * ".values"
        leaves = Dict{String,String}()
        for sec in sections
            val = _get_nested(cfg, sec)
            isnothing(val) && continue
            _collect_leaf_values!(leaves, sec, val)
        end
        open(values_file, "w") do io
            for (k, v) in sort(collect(leaves); by=first)
                println(io, "$k=$v")
            end
        end
    end

end
