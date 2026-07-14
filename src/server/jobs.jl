module JobQueue

# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

# In-memory job store. Single-user local server - no persistence needed.
    using Dates, UUIDs, JSON3

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

    # Keep at most this many settled jobs (prevents unbounded growth).
    const _MAX_FINISHED_JOBS = 50

    # SSE subscriber channels: each connected client gets a Channel{String}
    const _subscribers      = Vector{Channel{String}}()
    const _subscribers_lock = ReentrantLock()

    function _new_id()
        "job_" * replace(string(uuid4())[1:8], "-" => "")
    end

    ## Status transitions
    # complete, failed and cancelled are terminal: once a job reaches one of them its
    # status never changes again. Cancellation merely requests an interrupt, so
    # without this invariant the still-running task would demote a cancelled job to
    # failed (the InterruptException lands in its catch) or promote it to complete.
    const _TERMINAL_STATUSES = (complete, failed, cancelled)

    is_terminal(status::JobStatus) = status in _TERMINAL_STATUSES

    # Apply a status transition, refusing to move a job out of a terminal state.
    # Caller must hold `_jobs_lock`. Returns true when the transition was applied.
    function _transition!(job::Job, status::JobStatus;
                          message::Union{String,Nothing}=nothing,
                          finished::Bool=false)
        is_terminal(job.status) && return false
        job.status = status
        isnothing(message) || (job.message = message)
        finished && (job.finished_at = now(UTC))
        return true
    end

    # A job may be terminal and yet still executing, because cancel_job! only asks the
    # task to stop. Such a job is not settled: pruning it would orphan it, leaving its
    # task to mutate a Job the store no longer lists and to broadcast updates for it.
    # Caller must hold `_jobs_lock`.
    _is_settled(job::Job) = is_terminal(job.status) &&
                            (isnothing(job.task) || istaskdone(job.task))

    # Remove oldest settled jobs when the store exceeds the cap.
    # Must be called inside a lock(_jobs_lock) block.
    function _prune_finished!()
        settled = filter(p -> _is_settled(p.second), collect(_jobs))
        length(settled) <= _MAX_FINISHED_JOBS && return
        sort!(settled; by = p -> something(p.second.finished_at, p.second.created_at))
        n_remove = length(settled) - _MAX_FINISHED_JOBS
        for i in 1:n_remove
            id, job = settled[i]
            job.task = nothing  # release Task closure (large captured data)
            delete!(_jobs, id)
        end
    end

    function submit_job!(f::Function, type::String;
                        study=nothing, run=nothing, stage=nothing)
        id  = _new_id()
        job = Job(id, type, study, run, stage,
                queued, now(UTC), nothing, nothing, nothing)
        task = Task(() -> _run_job!(job, f))
        # As Threads.@spawn does, let the task run on any thread of the default pool.
        # It is created unscheduled and published under `_jobs_lock` before it starts,
        # because cancel_job! reads `job.task` under the same lock and would otherwise
        # find nothing there for a job that is already running.
        task.sticky = false
        lock(_jobs_lock) do
            job.task  = task
            _jobs[id] = job
            _prune_finished!()
        end
        schedule(task)
        return job
    end

    function _run_job!(job::Job, f::Function)
        started = lock(_jobs_lock) do
            _transition!(job, running)
        end
        # A job cancelled before its task got going is already terminal, so `f` is
        # never run and the cancelled status stands.
        if started
            _emit_job_update(job)
            try
                f()
                lock(_jobs_lock) do
                    _transition!(job, complete; finished=true)
                end
            catch e
                lock(_jobs_lock) do
                    _transition!(job, failed; message=sprint(showerror, e), finished=true)
                end
            end
        end
        _emit_job_update(job)
        if !isnothing(job.stage) && !isnothing(job.study)
            _emit_stage_update(job)
        end
        # Release the Task's closure so captured data (DataFrames, dbs, etc.) can be
        # garbage-collected. Held until the final broadcast has gone out, since a job
        # whose task is nothing counts as settled and may be pruned from under us.
        lock(_jobs_lock) do
            job.task = nothing
        end
        GC.gc(false)  # hint to the GC - non-full collection
        return nothing
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
        transitioned = lock(_jobs_lock) do
            _transition!(job, cancelled; finished=true) || return false
            task = job.task
            # Only a task that has started and not yet finished can take the interrupt.
            # The throw is best-effort: the task may be racing to a terminal state of
            # its own, and cancelled is terminal either way.
            if !isnothing(task) && istaskstarted(task) && !istaskdone(task)
                try
                    schedule(task, InterruptException(); error=true)
                catch e
                    @debug "cancel_job!: task could not be interrupted" id exception=e
                end
            end
            return true
        end
        # False when the job had already settled: there was nothing to cancel, and
        # saying otherwise tells the caller a cancellation happened that did not.
        transitioned && _emit_job_update(job)
        return transitioned
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

    # Offer a message to one subscriber without ever blocking. `put!` on a bounded
    # Channel blocks once the buffer is full, so the buffer is inspected under the
    # channel's own lock, which we keep held across the put! so that no other producer
    # can take the slot we just found. Returns false for a closed or full channel.
    function _offer!(ch::Channel{String}, msg::String)
        lock(ch)
        try
            isopen(ch) || return false
            length(ch.data) >= ch.sz_max && return false
            put!(ch, msg)
            return true
        catch
            return false  # channel was closed underneath us
        finally
            unlock(ch)
        end
    end

    function broadcast_event!(event::String, data::String)
        msg = "event: $event\ndata: $data\n\n"
        # Nothing that can block may run under `_subscribers_lock`: one stalled client
        # would otherwise hold it while its buffer stayed full, stopping every other
        # broadcast, subscribe and unsubscribe behind it, the _emit_job_update calls of
        # running jobs included. Deliver from a snapshot taken under the lock instead.
        subs = lock(_subscribers_lock) do
            copy(_subscribers)
        end
        dropped = Channel{String}[]
        for ch in subs
            _offer!(ch, msg) || push!(dropped, ch)
        end
        isempty(dropped) && return nothing
        # A subscriber that is closed, or too far behind to accept the message, is
        # disconnected: closing its channel ends its SSE loop, and the browser's
        # EventSource reconnects and resynchronises rather than reading a stream with
        # holes in it. A slow client thus degrades only itself.
        lock(_subscribers_lock) do
            filter!(ch -> !any(d -> d === ch, dropped), _subscribers)
        end
        for ch in dropped
            isopen(ch) && close(ch)
        end
        return nothing
    end

    # Interpolating the fields by hand escaped only `message`, so a study, run, or
    # stage name carrying a quote or a backslash emitted malformed JSON onto the
    # event stream. JSON3 escapes every field, and `nothing` renders as null.
    function _job_json(j::Job)
        JSON3.write((
            id          = j.id,
            type        = j.type,
            study       = j.study,
            run         = j.run,
            stage       = j.stage,
            status      = string(j.status),
            created_at  = string(j.created_at),
            finished_at = isnothing(j.finished_at) ? nothing : string(j.finished_at),
            message     = j.message,
        ))
    end

    # The job is serialised under `_jobs_lock` so that the payload is a coherent
    # snapshot even while the job's own task is mutating it; the broadcast itself runs
    # outside the lock.
    function _emit_job_update(j::Job)
        payload = lock(_jobs_lock) do
            _job_json(j)
        end
        broadcast_event!("job_update", payload)
    end

    function _emit_stage_update(j::Job)
        payload = lock(_jobs_lock) do
            (isnothing(j.study) || isnothing(j.stage)) && return nothing
            JSON3.write((study  = j.study,
                         run    = j.run,
                         stage  = j.stage,
                         status = string(j.status)))
        end
        isnothing(payload) && return nothing
        broadcast_event!("stage_update", payload)
    end

end
