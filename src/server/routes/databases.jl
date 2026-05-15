# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/databases
using JSON3, YAML

function _db_info()
    path = joinpath(dirname(ServerState.data_dir()), "config", "databases.yml")
    isfile(path) || return []
    cfg = get(YAML.load_file(path), "databases", Dict())
    map(filter(((k,v),) -> v isa Dict, collect(cfg))) do (key, entry)
        name  = get(entry, "label", string(key))
        dada2_path   = get(get(entry, "dada2",   Dict()), "local_path", nothing)
        vsearch_path = get(get(entry, "vsearch", Dict()), "local_path", nothing)
        db_dir = joinpath(dirname(ServerState.data_dir()), "databases")
        (;
            key     = string(key),
            label   = name,
            dada2_available   = !isnothing(dada2_path)   && isfile(joinpath(db_dir, basename(string(dada2_path)))),
            vsearch_available = !isnothing(vsearch_path) && isfile(joinpath(db_dir, basename(string(vsearch_path)))),
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
