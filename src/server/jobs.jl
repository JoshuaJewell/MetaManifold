module JobQueue

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

# In-memory job store. Single-user local server - no persistence needed.
    using Dates, UUIDs

export Job, JobStatus, submit_job!, get_job, list_jobs, cancel_job!,
        broadcast_event!, subscribe_events, unsubscribe_events

    @enum JobStatus queued running complete failed cancelled

    mutable struct Job
        id          :: String
        type        :: String          # "pipeline" | "stage" | "db_download"
        study       :: Union{String, Nothing}
        run         :: Union{String, Nothing}
        stage       :: Union{String, Nothing}
        status      :: JobStatus
        created_at  :: DateTime
        finished_at :: Union{DateTime, Nothing}
        message     :: Union{String, Nothing}
        task        :: Union{Task, Nothing}
    end

    const _jobs      = Dict{String, Job}()
    const _jobs_lock = ReentrantLock()

    # Keep at most this many finished jobs (prevents unbounded growth).
    const _MAX_FINISHED_JOBS = 50

    # SSE subscriber channels: each connected client gets a Channel{String}
    const _subscribers      = Vector{Channel{String}}()
    const _subscribers_lock = ReentrantLock()

    function _new_id()
        "job_" * replace(string(uuid4())[1:8], "-" => "")
    end

    # Remove oldest finished jobs when the store exceeds the cap.
    # Must be called inside a lock(_jobs_lock) block.
    function _prune_finished!()
        finished = filter(p -> p.second.status in (complete, failed, cancelled),
                          collect(_jobs))
        length(finished) <= _MAX_FINISHED_JOBS && return
        sort!(finished; by = p -> something(p.second.finished_at, p.second.created_at))
        n_remove = length(finished) - _MAX_FINISHED_JOBS
        for i in 1:n_remove
            id, job = finished[i]
            job.task = nothing  # release Task closure (large captured data)
            delete!(_jobs, id)
        end
    end

    function submit_job!(f::Function, type::String;
                        study=nothing, run=nothing, stage=nothing)
        id  = _new_id()
        job = Job(id, type, study, run, stage,
                queued, now(UTC), nothing, nothing, nothing)
        lock(_jobs_lock) do
            _jobs[id] = job
            _prune_finished!()
        end
        job.task = Threads.@spawn begin
            lock(_jobs_lock) do
                job.status = running
            end
            _emit_job_update(job)
            try
                f()
                lock(_jobs_lock) do
                    job.status      = complete
                    job.finished_at = now(UTC)
                end
            catch e
                lock(_jobs_lock) do
                    job.status      = failed
                    job.finished_at = now(UTC)
                    job.message     = sprint(showerror, e)
                end
            end
            # Release the Task's closure so captured data (DataFrames, dbs, etc.)
            # can be garbage-collected.  The Job struct keeps metadata but not the
            # heavyweight execution context.
            job.task = nothing
            GC.gc(false)  # hint to the GC - non-full collection
            _emit_job_update(job)
            if !isnothing(stage) && !isnothing(study)
                _emit_stage_update(job)
            end
        end
        return job
    end

    function get_job(id::String)
        lock(_jobs_lock) do
            get(_jobs, id, nothing)
        end
    end

    function list_jobs(; study=nothing, status=nothing)
        lock(_jobs_lock) do
            jobs = collect(values(_jobs))
            isnothing(study)  || filter!(j -> j.study == study,         jobs)
            isnothing(status) || filter!(j -> string(j.status) == status, jobs)
            sort!(jobs; by = j -> j.created_at, rev=true)
        end
    end

    function cancel_job!(id::String)
        job = get_job(id)
        isnothing(job) && return false
        lock(_jobs_lock) do
            if job.status in (queued, running)
                job.status      = cancelled
                job.finished_at = now(UTC)
                isnothing(job.task) || schedule(job.task, InterruptException(); error=true)
            end
        end
        _emit_job_update(job)
        return true
    end

    ## SSE helpers
    function subscribe_events()
        ch = Channel{String}(256)
        lock(_subscribers_lock) do
            push!(_subscribers, ch)
        end
        return ch
    end

    function unsubscribe_events(ch::Channel{String})
        lock(_subscribers_lock) do
            filter!(!=(ch), _subscribers)
        end
        close(ch)
    end

    function broadcast_event!(event::String, data::String)
        msg = "event: $event\ndata: $data\n\n"
        lock(_subscribers_lock) do
            # Prune closed/stale channels while broadcasting
            filter!(_subscribers) do ch
                if !isopen(ch)
                    return false
                end
                try
                    put!(ch, msg)
                catch
                    return false  # channel was closed between check and put
                end
                true
            end
        end
    end

    function _job_json(j::Job)
        """{"id":"$(j.id)","type":"$(j.type)",""" *
        """"study":$(isnothing(j.study) ? "null" : "\"$(j.study)\""),""" *
        """"run":$(isnothing(j.run) ? "null" : "\"$(j.run)\""),""" *
        """"stage":$(isnothing(j.stage) ? "null" : "\"$(j.stage)\""),""" *
        """"status":"$(j.status)",""" *
        """"created_at":"$(j.created_at)",""" *
        """"finished_at":$(isnothing(j.finished_at) ? "null" : "\"$(j.finished_at)\""),""" *
        """"message":$(isnothing(j.message) ? "null" : "\"$(escape_string(j.message))\"")"""  *
        "}"
    end

    function _emit_job_update(j::Job)
        broadcast_event!("job_update", _job_json(j))
    end

    function _emit_stage_update(j::Job)
        isnothing(j.study) || isnothing(j.stage) && return
        data = """{"study":"$(j.study)","run":$(isnothing(j.run) ? "null" : "\"$(j.run)\""),"stage":"$(j.stage)","status":"$(j.status)"}"""
        broadcast_event!("stage_update", data)
    end

end
