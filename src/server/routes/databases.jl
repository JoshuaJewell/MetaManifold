# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/databases
using JSON3, YAML
using MetaManifold.DatabasesLibrary

## Databases document (whole-file view and edit)
_databases_path() = joinpath(dirname(ServerState.data_dir()), "config", "databases.yml")

# Atomic write of a document already in the native file shape. The temp file and
# rename mean a reader never observes a half-written file, and the lock means two
# concurrent writes cannot interleave their bytes into a corrupt file. It does
# NOT make read-validate-write atomic: two clients can each read the document
# before either writes, and the later write silently overwrites the earlier
# client's edit (a lost update, not a torn file).
function _write_databases(native::AbstractDict)
    _atomic_write_yaml(_databases_path(), native)
end

# Read the document, turning an unparseable file into a 400 that names it rather
# than a 500. DatabasesLibrary.load deliberately raises instead of degrading to
# an empty document, because an empty document would breeze through validation
# and the next Save would overwrite the real config with nothing.
# Returns the document, or an HTTP.Response error.
function _read_databases()
    try
        DatabasesLibrary.load(_databases_path())
    catch e
        @error "databases.yml is not readable" path=_databases_path() exception=(e, catch_backtrace())
        json_error(400, "databases_unreadable",
            "config/databases.yml cannot be read as a databases document and must be repaired by hand: $(sprint(showerror, e))")
    end
end

# Parse a request body into a databases document. A body that is absent, not
# JSON, or JSON that is not a top-level object would otherwise throw out of the
# route and surface as a bare 500; this route backs a Save button, where a
# malformed request is a plausible client bug and deserves an actionable message.
# Returns the document, or an HTTP.Response error.
function _databases_body(body::AbstractString)
    parsed = try
        JSON3.read(body)
    catch e
        return json_error(400, "invalid_json",
            "Request body is not valid JSON: $(sprint(showerror, e))")
    end
    parsed isa JSON3.Object || return json_error(400, "invalid_json",
        "Request body must be a JSON object with dir and databases")
    _to_plain(parsed)
end

# Validate then write. Returns the saved canonical document, or an HTTP.Response
# error. The single gate every databases write passes through. The native shape is
# converted once and handed to both the gate and the write.
function _save_databases(doc::AbstractDict)
    native = DatabasesLibrary.to_yaml_doc(doc)
    errors = DatabasesLibrary.validate(doc; native)
    isempty(errors) || return json_error(400, "invalid_databases", join(errors, "; "))
    _write_databases(native)
    @info "Saved databases document ($(_databases_path()))"
    doc
end

# A version-like token in a URI's basename, e.g. v5.1.1 or 5.1.1. Returns the
# first match, or nothing. This is a filename heuristic and nothing more: it
# cannot speak for a database whose URIs carry no version.
function _version_token(uri::AbstractString)
    m = match(r"(\d+\.\d+(?:\.\d+)*)", basename(String(uri)))
    isnothing(m) ? nothing : m.captures[1]
end

# Advisory warnings for a submitted document. Never blocks a write.
#
# `current` is passed in rather than re-read here. The handler has already loaded
# it through `_read_databases`, which catches the deliberate raise on an
# unparseable file; loading it again here would escape that guard and throw,
# turning a Save into a 500 if the file changed underneath us between the reads.
function _database_warnings(doc::AbstractDict, current::AbstractDict)
    warnings = Any[]
    was = Set(DatabasesLibrary.database_keys(current))
    now = Set(DatabasesLibrary.database_keys(doc))
    # Which projects resolve to each database, through the real cascade. Every
    # project inherits dada2.taxonomy.database from the factory defaults without
    # naming it, so a name-scan would report nothing while the edit breaks all.
    refs = _cascade_refs("dada2.taxonomy.database")

    # A rename reads as the old key disappearing, so this covers rename and
    # deletion alike.
    for key in sort(collect(setdiff(was, now)))
        haskey(refs, key) || continue
        push!(warnings, Dict("kind" => "database_removed", "database" => key,
                             "used_by" => refs[key]))
    end

    for key in sort(collect(intersect(was, now)))
        before = DatabasesLibrary.levels_of(current, key)
        after  = DatabasesLibrary.levels_of(doc, key)
        before == after && continue
        haskey(refs, key) || continue
        push!(warnings, Dict("kind" => "levels_changed", "database" => key,
                             "used_by" => refs[key]))
    end

    # Both formats must come from one release: the consensus rank compares the
    # DADA2 and VSEARCH labels for string equality, so references drawn from
    # different releases score genuine agreements as disagreements.
    #
    # `_seq`, not a bare `get(doc, "databases", Any[])`: the default only fires
    # when the key is ABSENT, so an explicit `databases: null` reaches a bare
    # `get` as `nothing`, which throws on iteration. Every other site that walks
    # this section (all five in DatabasesLibrary) already goes through `_seq`;
    # this was the one that bypassed it.
    for e in Validation._seq(get(doc, "databases", nothing))
        e isa AbstractDict || continue
        d = get(e, "dada2", nothing); v = get(e, "vsearch", nothing)
        (d isa AbstractDict && v isa AbstractDict) || continue
        dv = _version_token(string(get(d, "uri", "")))
        vv = _version_token(string(get(v, "uri", "")))
        (isnothing(dv) && isnothing(vv)) && continue
        dv == vv && continue
        push!(warnings, Dict("kind" => "release_mismatch",
                             "database" => string(get(e, "key", "")),
                             "dada2_version" => something(dv, ""),
                             "vsearch_version" => something(vv, "")))
    end
    warnings
end

# The whole databases document in canonical shape.
@get "/api/v1/databases/document" function(req)
    doc = _read_databases()
    doc isa HTTP.Response && return doc
    json(doc)
end

# Replace the whole databases document. Validated before the write lands on disk.
# The response carries advisory warnings: removing or renaming a database a study
# resolves to, changing a database's levels, and a cross-release URI pair. None
# of them blocks the write. The read of the current document comes first: when
# the file on disk is corrupt we refuse the write rather than let it be
# overwritten from an empty editor.
@put "/api/v1/databases" function(req)
    current = _read_databases()
    current isa HTTP.Response && return current
    doc = _databases_body(String(req.body))
    doc isa HTTP.Response && return doc
    warnings = _database_warnings(doc, current)
    result = _save_databases(doc)
    result isa HTTP.Response && return result
    json(Dict("document" => result, "warnings" => warnings))
end

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
