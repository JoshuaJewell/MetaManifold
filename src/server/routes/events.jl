# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: /api/v1/events  (global SSE stream)
#
# Uses Oxygen's @stream macro which passes an HTTP.Streams.Stream object,
# allowing us to write SSE frames incrementally to the client.
using HTTP

@stream "/api/v1/events" function(stream::HTTP.Stream)
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type"      => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control"     => "no-cache")
    HTTP.setheader(stream, "Connection"        => "keep-alive")
    HTTP.setheader(stream, "X-Accel-Buffering" => "no")
    ch = subscribe_events()
    try
        HTTP.startwrite(stream)
        write(stream, ": connected\n\n")
        last_keepalive = time()
        while isopen(stream) && isopen(ch)
            if isready(ch)
                write(stream, take!(ch))
            else
                # Send keepalive every 15s to prevent proxy timeouts
                if time() - last_keepalive >= 15
                    write(stream, ": keepalive\n\n")
                    last_keepalive = time()
                end
                sleep(0.1)  # Short poll - events arrive within 100ms
            end
        end
    catch e
        # Client disconnected mid-write - this is normal SSE behaviour
        e isa Base.IOError || rethrow()
    finally
        unsubscribe_events(ch)
    end
end
