# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/jobs
using JSON3

function _job_to_namedtuple(j::Job)
    (; j.id, j.type,
       scope    = (; study=j.study, run=j.run),
       j.stage, j.message,
       status      = string(j.status),
       created_at  = string(j.created_at),
       finished_at = isnothing(j.finished_at) ? nothing : string(j.finished_at))
end

@get "/api/v1/jobs" function(req)
    study  = get(queryparams(req), "study",  nothing)
    status = get(queryparams(req), "status", nothing)
    jobs   = list_jobs(; study, status)
    json(map(_job_to_namedtuple, jobs))
end

@get "/api/v1/jobs/{id}" function(req, id::String)
    j = get_job(id)
    isnothing(j) && return json_error(404, "job_not_found", "Job '$id' not found")
    json(_job_to_namedtuple(j))
end

@get "/api/v1/jobs/{id}/logs" function(req, id::String)
    j = get_job(id)
    isnothing(j) && return json_error(404, "job_not_found", "Job '$id' not found")
    HTTP.Response(501, ["Content-Type" => "application/json"],
        body = JSON3.write((; error="not_implemented",
                             message="Log streaming is not yet implemented")))
end

@delete "/api/v1/jobs/{id}" function(req, id::String)
    # Existence and cancellability are different questions. `cancel_job!` returns
    # false when the job had already settled, which is not a 404: the job is there,
    # there was simply nothing left to cancel. Deleting an already-finished job is
    # idempotent and succeeds.
    isnothing(get_job(id)) && return json_error(404, "job_not_found", "Job '$id' not found")
    cancel_job!(id)
    HTTP.Response(204)
end
