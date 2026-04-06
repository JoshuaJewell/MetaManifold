import { useEffect, useRef, useState } from 'react'
import { openEventStream, type SSEHandler } from '../api/events'

/**
 * Subscribe to the global SSE stream. Pass a stable handlers object
 * (e.g. via useMemo) to avoid reconnecting on every render.
 * Returns whether the SSE connection is currently open.
 */
export function useSSE(handlers: SSEHandler): boolean {
  const ref = useRef(handlers)
  ref.current = handlers
  const [connected, setConnected] = useState(false)

  useEffect(() => {
    return openEventStream({
      onJobUpdate:   (job)  => ref.current.onJobUpdate?.(job),
      onStageUpdate: (ev)   => ref.current.onStageUpdate?.(ev),
      onConnectedChange: setConnected,
    })
  }, [])

  return connected
}
