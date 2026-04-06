import type { Job, StageStatus } from './types'
import { apiUrl } from './client'

export type SSEHandler = {
  onJobUpdate?:   (job: Job) => void
  onStageUpdate?: (ev: { study: string; run: string | null; stage: string; status: StageStatus }) => void
}

/**
 * Open a persistent SSE connection to /api/v1/events.
 * Returns a cleanup function - call it to close the connection.
 */
export function openEventStream(handlers: SSEHandler & { onConnectedChange?: (connected: boolean) => void }): () => void {
  const es = new EventSource(apiUrl('/api/v1/events'))

  es.addEventListener('job_update', (e: MessageEvent) => {
    handlers.onJobUpdate?.(JSON.parse(e.data) as Job)
  })

  es.addEventListener('stage_update', (e: MessageEvent) => {
    handlers.onStageUpdate?.(JSON.parse(e.data))
  })

  es.onopen = () => handlers.onConnectedChange?.(true)

  es.onerror = () => {
    handlers.onConnectedChange?.(false)
    // Browser auto-reconnects; onopen will fire again when it does.
  }

  return () => es.close()
}
