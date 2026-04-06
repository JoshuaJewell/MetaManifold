module Server

    # © 2026 Joshua Benjamin Jewell. All rights reserved.
    #
    # This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

    # MetaManifold WebUI backend
    #
    # Start with:
    #   julia --project=. src/server/server.jl
    # or from a Julia session:
    #   include("src/server/server.jl"); Server.start()
    # or via start.sh

    using MetaManifold
    using Oxygen, HTTP, JSON3, YAML, Logging

    using MetaManifold.PipelineTypes, MetaManifold.PipelineLog, MetaManifold.Config
    using MetaManifold.Databases, MetaManifold.DuckDBStore
    using MetaManifold.FuncDBAnnotation
    using MetaManifold.Tools, MetaManifold.TaxonomyTableTools, MetaManifold.ProjectSetup
    using MetaManifold.DADA2, MetaManifold.OTUPipeline
    using MetaManifold.DiversityMetrics, MetaManifold.Analysis

    ## EPIPE log filter
    #
    # HTTP.jl logs every broken-pipe error from SSE streams as @error
    # "handle_connection handler error". These are harmless (client closed the
    # connection) but very noisy. Filter them before they reach the console.

    struct _SuppressEpipe{L<:AbstractLogger} <: AbstractLogger
        inner::L
    end
    Logging.min_enabled_level(l::_SuppressEpipe) = Logging.min_enabled_level(l.inner)
    Logging.shouldlog(l::_SuppressEpipe, args...) = Logging.shouldlog(l.inner, args...)
    function Logging.handle_message(l::_SuppressEpipe, level, msg, _module, group, id, file, line; kwargs...)
        # HTTP.jl embeds the exception as text inside the message string via
        # current_exceptions_to_string() - it is NOT passed as kwargs[:exception].
        # Match on the message text itself.
        msg_str = string(msg)
        if occursin("handle_connection handler error", msg_str) &&
           (occursin("EPIPE", msg_str) || occursin("broken pipe", msg_str))
            return
        end
        try
            Logging.handle_message(l.inner, level, msg, _module, group, id, file, line; kwargs...)
        catch e
            # When a job is stopped the TTY handle becomes invalid. uv_write()
            # then returns Nothing instead of Int32, triggering a TypeError
            # before Julia can turn it into an IOError/EPIPE. Suppress both so
            # "Exception while generating log record" spam is silenced on cancel.
            (e isa Base.IOError || e isa TypeError) && return
            rethrow()
        end
    end

    ## Server state

    module ServerState
        const _root = Ref{String}("")
        data_dir()     = joinpath(_root[], "data")
        projects_dir() = joinpath(_root[], "projects")
        set_root!(path::String) = (_root[] = abspath(path))
    end

    ## Job queue

    include(joinpath(@__DIR__, "jobs.jl"))
    using .JobQueue

    ## Shared helpers (available to all included route files)

    function json_error(status::Int, code::String, message::String; detail=nothing)
        body = isnothing(detail) ? (; error=code, message) : (; error=code, message, detail)
        HTTP.Response(status,
            ["Content-Type" => "application/json"],
            body = JSON3.write(body))
    end

    ## Routes

    include(joinpath(@__DIR__, "routes", "duckdb_helpers.jl"))
    include(joinpath(@__DIR__, "routes", "studies.jl"))
    include(joinpath(@__DIR__, "routes", "runs.jl"))
    include(joinpath(@__DIR__, "routes", "config.jl"))
    include(joinpath(@__DIR__, "routes", "pipeline.jl"))
    include(joinpath(@__DIR__, "routes", "jobs.jl"))
    include(joinpath(@__DIR__, "routes", "results.jl"))
    include(joinpath(@__DIR__, "routes", "annotations.jl"))
    include(joinpath(@__DIR__, "routes", "databases.jl"))
    include(joinpath(@__DIR__, "routes", "events.jl"))
    include(joinpath(@__DIR__, "routes", "analysis.jl"))
    include(joinpath(@__DIR__, "routes", "composition.jl"))

    ## CORS middleware (needed when the frontend is served from a different origin)

    function _cors_middleware(next)
        function(req::HTTP.Request)
            origin = HTTP.header(req, "Origin", "")
            if isempty(origin)
                # Same-origin request - no CORS headers needed
                return next(req)
            end
            # Only allow localhost origins
            origin_url = try HTTP.URIs.URI(origin) catch; nothing end
            if isnothing(origin_url) || !(lowercase(origin_url.host) in ("localhost", "127.0.0.1", "::1"))
                return HTTP.Response(403, "Forbidden: non-localhost origin")
            end
            cors_headers = [
                "Access-Control-Allow-Origin"  => origin,
                "Access-Control-Allow-Methods" => "GET, POST, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers" => "Content-Type",
            ]
            # Handle preflight
            if req.method == "OPTIONS"
                return HTTP.Response(204, cors_headers)
            end
            resp = next(req)
            for (k, v) in cors_headers
                HTTP.setheader(resp, k => v)
            end
            resp
        end
    end

    ## Static file serving (frontend build + on-demand PDFs)

    const _frontend_dir = joinpath(@__DIR__, "..", "..", "web", "dist")
    const _mime_map = Dict(
        ".html" => "text/html", ".js" => "application/javascript",
        ".css"  => "text/css",  ".png" => "image/png",
        ".svg"  => "image/svg+xml", ".pdf" => "application/pdf",
        ".csv"  => "text/csv",  ".json" => "application/json",
    )

    # Static file serving middleware (Oxygen middleware signature: handler -> req -> response)
    function _file_middleware(next)
        function(req::HTTP.Request)
            uri = first(split(req.target, '?'; limit=2))

            # /files/{study}/runs/{rest...} -> serve from projects/{study}/{rest}
            # rest may be {run}/... or {group}/{run}/... (group paths have an extra segment)
            m = match(r"^/files/([^/]+)/runs/(.+)$", uri)
            if !isnothing(m)
                candidate = abspath(joinpath(ServerState.projects_dir(), HTTP.URIs.unescapeuri(m[1]), HTTP.URIs.unescapeuri(m[2])))
                isfile(candidate) || return HTTP.Response(404, "File not found")
                full     = realpath(candidate)
                projects = realpath(ServerState.projects_dir())
                startswith(full, projects * Base.Filesystem.path_separator) ||
                    return HTTP.Response(403, "Forbidden")
                ext  = last(splitext(full))
                mime = get(_mime_map, ext, "application/octet-stream")
                return HTTP.Response(200, ["Content-Type" => mime]; body=read(full))
            end

            # Pass API requests through to Oxygen
            startswith(uri, "/api/") && return next(req)

            # SPA catch-all: serve frontend build or index.html
            rel    = lstrip(uri, '/')
            target = joinpath(_frontend_dir, rel)
            if isfile(target)
                ext  = last(splitext(target))
                mime = get(_mime_map, ext, "application/octet-stream")
                # Content-hashed assets (js/css in assets/) are immutable.
                # Everything else (index.html, config.json) must not be cached so
                # the browser always loads the latest bundle after a rebuild.
                cache = (ext in (".js", ".css") && occursin("/assets/", uri)) ?
                    "public, max-age=31536000, immutable" : "no-store"
                return HTTP.Response(200,
                    ["Content-Type" => mime, "Cache-Control" => cache];
                    body=read(target))
            end
            index = joinpath(_frontend_dir, "index.html")
            isfile(index) && return HTTP.Response(200,
                ["Content-Type" => "text/html", "Cache-Control" => "no-store"];
                body=read(index))
            # No frontend build yet - fall through to Oxygen (404)
            next(req)
        end
    end

    ## Entry point

    function start(; root=pwd(), host="127.0.0.1", port=8080, listen::Bool=true)
        global_logger(_SuppressEpipe(global_logger()))
        ServerState.set_root!(root)
        @info "MetaManifold server starting" root host port

        # Initialise all projects on startup
        initialised = _ensure_all_projects()
        isempty(initialised) || @info "Initialised projects" initialised

        listen || return nothing
        serve(; host, port, access_log=nothing, middleware=[_cors_middleware, _file_middleware], show_errors=false)
    end

end

# Allow running directly: julia src/server/server.jl
# Respects env vars JULIA_METAMANIFOLD_ROOT and JULIA_METAMANIFOLD_PORT for
# headless/subprocess startup (e.g. integration tests).
if abspath(PROGRAM_FILE) == @__FILE__
    root = get(ENV, "JULIA_METAMANIFOLD_ROOT", pwd())
    port = parse(Int, get(ENV, "JULIA_METAMANIFOLD_PORT", "8080"))
    Server.start(; root, port)
end
