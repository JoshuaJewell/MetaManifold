# Unit tests for the job queue's concurrency invariants and for the per-database
# serialisation of the DuckDB store.
#
# jobs.jl is `module JobQueue` inside `module Server`, so the server module is
# included here exactly as test_routes.jl does; including it does not start the
# HTTP listener.
if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end
JQ  = Main.Server.JobQueue
DBS = MetaManifold.DuckDBStore

# A job is settled once it is terminal and its task has actually finished.
jq_settled(job) = lock(JQ._jobs_lock) do
    JQ._is_settled(job)
end

jq_wait_settled(job) = timedwait(() -> jq_settled(job), 60.0; pollint=0.01)

# Wait until some task is parked in `take!(ch)`. Throwing an InterruptException into a
# task that is still running would enqueue a running task, which is unsound; the tests
# therefore only cancel a job whose task has demonstrably yielded.
jq_wait_parked(ch::Channel) = timedwait(60.0; pollint=0.01) do
    lock(ch) do
        !isempty(ch.cond_take.waitq)
    end
end

@testset "JobQueue" begin

    ## Terminal states are terminal: no transition may leave complete, failed or
    ## cancelled, whatever the job's task subsequently tries to record.
    @testset "terminal states stay terminal" begin
        for terminal in (JQ.complete, JQ.failed, JQ.cancelled)
            job = JQ.Job("job_test", "pipeline", nothing, nothing, nothing,
                         JQ.queued, now(UTC), nothing, nothing, nothing)
            lock(JQ._jobs_lock) do
                @test JQ._transition!(job, JQ.running)
                @test JQ._transition!(job, terminal; finished=true)
                @test !JQ._transition!(job, JQ.complete; finished=true)
                @test !JQ._transition!(job, JQ.failed; message="boom", finished=true)
                @test !JQ._transition!(job, JQ.cancelled; finished=true)
                @test !JQ._transition!(job, JQ.running)
            end
            @test job.status == terminal
            @test isnothing(job.message)
            @test JQ.is_terminal(job.status)
        end
    end

    @testset "a job that runs to completion reports complete" begin
        job = JQ.submit_job!("pipeline") do
            nothing
        end
        @test jq_wait_settled(job) === :ok
        @test job.status == JQ.complete
        @test !isnothing(job.finished_at)
        @test isnothing(job.task)
        # A terminal job cannot be dragged back out of its state by a late cancel,
        # and the cancel reports that it cancelled nothing rather than claiming a
        # success that did not happen.
        @test !JQ.cancel_job!(job.id)
        @test job.status == JQ.complete
    end

    @testset "a job that throws reports failed" begin
        job = JQ.submit_job!("pipeline") do
            error("deliberate failure")
        end
        @test jq_wait_settled(job) === :ok
        @test job.status == JQ.failed
        @test occursin("deliberate failure", job.message)
    end

    ## The InterruptException thrown in by cancel_job! lands in the task's own catch
    ## block, which used to record the job as failed.
    @testset "cancelling a running job reports cancelled, not failed" begin
        started = Channel{Nothing}(1)
        gate    = Channel{Nothing}(1)
        job = JQ.submit_job!("pipeline"; study="s1", run="r1") do
            put!(started, nothing)
            take!(gate)
        end
        take!(started)
        @test jq_wait_parked(gate) === :ok
        @test JQ.cancel_job!(job.id)
        @test job.status == JQ.cancelled
        @test jq_wait_settled(job) === :ok
        @test job.status == JQ.cancelled
        @test isnothing(job.message)
        close(gate)
    end

    ## submit_job! publishes the task under the store's lock before scheduling it, so a
    ## job cancelled while queued reaches its task already terminal.
    @testset "a job cancelled before it starts never runs its body" begin
        job = JQ.Job("job_precancelled", "pipeline", nothing, nothing, nothing,
                     JQ.cancelled, now(UTC), now(UTC), nothing, nothing)
        ran = Threads.Atomic{Int}(0)
        JQ._run_job!(job, () -> Threads.atomic_add!(ran, 1))
        @test ran[] == 0
        @test job.status == JQ.cancelled
    end

    ## Cancellation only requests an interrupt. A task that has not yet stopped must
    ## keep its slot in the store, or it would go on mutating a Job nobody lists.
    @testset "a cancelled but still running job is not pruned" begin
        entered  = Channel{Nothing}(1)
        absorbed = Channel{Nothing}(1)
        release  = Channel{Nothing}(1)
        sticky = JQ.submit_job!("pipeline") do
            put!(entered, nothing)
            while true
                try
                    take!(release)
                    break
                catch e
                    e isa InterruptException || rethrow()
                    put!(absorbed, nothing)
                end
            end
        end
        take!(entered)
        @test jq_wait_parked(release) === :ok
        @test JQ.cancel_job!(sticky.id)
        take!(absorbed)  # the task swallowed the interrupt and is still running
        @test sticky.status == JQ.cancelled
        @test !jq_settled(sticky)

        # Push the store past its cap of settled jobs, so that every submission prunes.
        for _ in 1:(JQ._MAX_FINISHED_JOBS + 5)
            filler = JQ.submit_job!("pipeline") do
                nothing
            end
            @test jq_wait_settled(filler) === :ok
        end
        @test !isnothing(JQ.get_job(sticky.id))
        # Pruning runs on submission, so the last filler settles after the prune its own
        # submission triggered: the cap admits that one straggler.
        @test count(jq_settled, JQ.list_jobs()) <= JQ._MAX_FINISHED_JOBS + 1

        # Letting the task finish must not promote the cancelled job to complete.
        put!(release, nothing)
        @test jq_wait_settled(sticky) === :ok
        @test sticky.status == JQ.cancelled
        @test !isnothing(JQ.get_job(sticky.id))
    end

    ## A subscriber whose bounded buffer has filled must degrade only itself: put! on a
    ## full Channel blocks, and blocking under _subscribers_lock would stall every
    ## broadcast, subscribe and unsubscribe behind it.
    @testset "broadcast_event! never blocks on a full subscriber" begin
        stalled = Channel{String}(1)
        put!(stalled, "filler")  # at capacity
        lock(JQ._subscribers_lock) do
            push!(JQ._subscribers, stalled)
        end
        healthy = JQ.subscribe_events()

        caster = Threads.@spawn JQ.broadcast_event!("job_update", "{\"id\":\"x\"}")
        @test timedwait(() -> istaskdone(caster), 30.0; pollint=0.01) === :ok
        wait(caster)

        # The healthy subscriber is served even though the stalled one comes first.
        @test isready(healthy)
        @test occursin("job_update", take!(healthy))
        # The stalled subscriber is dropped and closed rather than blocking the sender.
        @test !isopen(stalled)
        still_listed = lock(JQ._subscribers_lock) do
            any(ch -> ch === stalled, JQ._subscribers)
        end
        @test !still_listed

        # Subscribing and broadcasting still work once the stalled client is gone.
        JQ.broadcast_event!("job_update", "{\"id\":\"y\"}")
        @test occursin("\"y\"", take!(healthy))
        JQ.unsubscribe_events(healthy)
        @test !isopen(healthy)
    end
end

@testset "DuckDB store serialisation" begin

    dir = mktempdir()
    write(joinpath(dir, "merged.csv"), "SeqName,s1\nseq1,10\n")
    DBS.load_results_db(dir)
    db_path = joinpath(dir, "results.duckdb")

    ## DuckDB permits one writer or several readers; the store must enforce that
    ## itself, since two handles racing for the file lock simply throw.
    @testset "a writer excludes other writers and readers" begin
        entered = Base.Event()
        release = Base.Event()
        writer = Threads.@spawn DBS.with_results_db_write(dir) do con
            DBInterface.execute(con, "CREATE TABLE hold (i INTEGER)")
            notify(entered)
            wait(release)
            DBInterface.execute(con, "INSERT INTO hold VALUES (1)")
        end
        wait(entered)

        second = Threads.@spawn DBS.with_results_db_write(dir) do con
            DBInterface.execute(con, "INSERT INTO hold VALUES (2)")
        end
        reader = Threads.@spawn DBS.with_results_db(dir) do con
            DataFrame(DBInterface.execute(con, "SELECT count(*) AS n FROM hold")).n[1]
        end
        @test timedwait(() -> istaskdone(second), 2.0; pollint=0.05) === :timed_out
        @test timedwait(() -> istaskdone(reader), 0.5; pollint=0.05) === :timed_out

        notify(release)
        @test timedwait(() -> istaskdone(second) && istaskdone(reader),
                        60.0; pollint=0.01) === :ok
        wait(writer)
        wait(second)
        wait(reader)  # a file-lock collision would surface here

        rows = DBS.with_results_db(dir) do con
            DataFrame(DBInterface.execute(con, "SELECT count(*) AS n FROM hold")).n[1]
        end
        @test rows == 2
    end

    @testset "concurrent writers all succeed and never overlap" begin
        inflight = Threads.Atomic{Int}(0)
        peak     = Threads.Atomic{Int}(0)
        writers  = map(1:4) do k
            Threads.@spawn DBS.with_results_db_write(dir) do con
                current = Threads.atomic_add!(inflight, 1) + 1
                Threads.atomic_max!(peak, current)
                DBInterface.execute(con, "INSERT INTO hold VALUES ($(10 + k))")
                yield()  # any competing writer gets its chance here
                Threads.atomic_sub!(inflight, 1)
            end
        end
        foreach(wait, writers)
        @test peak[] == 1
        rows = DBS.with_results_db(dir) do con
            DataFrame(DBInterface.execute(con, "SELECT count(*) AS n FROM hold")).n[1]
        end
        @test rows == 6
    end

    @testset "readers share the database" begin
        entered = Base.Event()
        release = Base.Event()
        holder = Threads.@spawn DBS.with_results_db(dir) do con
            DBInterface.execute(con, "SELECT 1")
            notify(entered)
            wait(release)
        end
        wait(entered)
        second = Threads.@spawn DBS.with_results_db(dir) do con
            DataFrame(DBInterface.execute(con, "SELECT count(*) AS n FROM hold")).n[1]
        end
        # A second reader must not wait on the first.
        @test timedwait(() -> istaskdone(second), 30.0; pollint=0.01) === :ok
        @test fetch(second) == 6
        notify(release)
        wait(holder)
    end

    ## The route helpers open these databases from tasks that may already hold them, so
    ## the lock must be re-entrant rather than self-deadlocking.
    @testset "the per-path lock is re-entrant" begin
        @test DBS._with_db_lock(db_path, true) do
            DBS._with_db_lock(db_path, true) do
                :nested_write
            end
        end === :nested_write

        @test DBS._with_db_lock(db_path, false) do
            DBS._with_db_lock(db_path, false) do
                :nested_read
            end
        end === :nested_read

        @test DBS._with_db_lock(db_path, true) do
            DBS._with_db_lock(db_path, false) do
                :read_inside_write
            end
        end === :read_inside_write

        # Upgrading a read hold to a write hold cannot be serialised; it must say so
        # rather than hang.
        @test_throws ErrorException DBS._with_db_lock(db_path, false) do
            DBS._with_db_lock(db_path, true) do
                :never
            end
        end

        # The failed upgrade released everything it took.
        @test DBS._with_db_lock(db_path, true) do
            :free
        end === :free
    end

    @testset "a missing database still errors" begin
        empty_dir = mktempdir()
        @test_throws ErrorException DBS.with_results_db(identity, empty_dir)
        @test_throws ErrorException DBS.with_results_db_write(identity, empty_dir)
    end
end
