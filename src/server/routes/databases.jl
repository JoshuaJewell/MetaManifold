# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/databases
using JSON3, YAML

# A format is present when its `local:` override names a file that exists, or when
# the asset named by its `uri:` has been downloaded into the databases cache. The
# config schema has no `local_path` key, only `uri`, `local`, and `remote_path`, so
# reading `local_path` meant every database reported itself unavailable regardless
# of what was actually on disk.
function _format_available(entry::AbstractDict, format::String, db_dir::String)
    info = get(entry, format, nothing)
    info isa AbstractDict || return false

    override = get(info, "local", nothing)
    if !isnothing(override) && !isempty(string(override))
        return isfile(string(override))
    end

    uri = get(info, "uri", nothing)
    isnothing(uri) && return false
    isfile(joinpath(db_dir, basename(string(uri))))
end

function _db_info()
    path = joinpath(dirname(ServerState.data_dir()), "config", "databases.yml")
    isfile(path) || return []
    cfg = get(YAML.load_file(path), "databases", Dict())
    # The cache directory is `databases.dir`, exactly as `Databases.ensure_databases`
    # resolves it. Hard-coding "databases/" here would report every database
    # unavailable on any deployment that sets the key, while the pipeline resolved it
    # perfectly well.
    db_dir = abspath(get(cfg, "dir", "./databases"))
    map(filter(((k,v),) -> v isa Dict, collect(cfg))) do (key, entry)
        (;
            key     = string(key),
            label   = get(entry, "label", string(key)),
            dada2_available   = _format_available(entry, "dada2",   db_dir),
            vsearch_available = _format_available(entry, "vsearch", db_dir),
        )
    end
end

@get "/api/v1/databases" function(req)
    json(_db_info())
end

@post "/api/v1/databases/{key}/download" function(req, key::String)
    db_cfg = joinpath(dirname(ServerState.data_dir()), "config", "databases.yml")
    isfile(db_cfg) || return json_error(404, "config_not_found",
                                            "databases.yml not found")
    cfg = get(YAML.load_file(db_cfg), "databases", Dict())
    haskey(cfg, key) || return json_error(404, "database_unavailable",
                                              "Database '$key' not configured")
    job = submit_job!("db_download"; study=nothing) do
        ensure_databases(db_cfg)
    end
    json(_job_to_namedtuple(job))
end
