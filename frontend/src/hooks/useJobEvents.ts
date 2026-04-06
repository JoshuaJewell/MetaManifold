import { createContext, useContext, useEffect, useRef } from 'react'
import type { Job } from '../api/types'

type Listener = (job: Job) => void

export interface JobEventBus {
  subscribe:   (fn: Listener) => () => void
  emit:        (job: Job) => void
}

/** Create a bus instance (call once at app root). */
export function createJobEventBus(): JobEventBus {
  const listeners = new Set<Listener>()
  return {
    subscribe(fn) {
      listeners.add(fn)
      return () => { listeners.delete(fn) }
    },
    emit(job) {
      for (const fn of listeners) fn(job)
    },
  }
}

export const JobEventContext = createContext<JobEventBus | null>(null)
export const SSEConnectedContext = createContext<boolean>(false)

export function useSSEConnected(): boolean {
  return useContext(SSEConnectedContext)
}

/**
 * Refetch when a job matching the filter completes (or fails).
 * `filter` should be a stable object or memoised.
 */
export function useJobRefetch(
  refetch: () => void,
  filter: { study?: string; run?: string },
) {
  const bus = useContext(JobEventContext)
  const filterRef = useRef(filter)
  filterRef.current = filter
  const refetchRef = useRef(refetch)
  refetchRef.current = refetch

  useEffect(() => {
    if (!bus) return
    return bus.subscribe((job) => {
      if (job.status !== 'complete' && job.status !== 'failed' && job.status !== 'running') return
      const f = filterRef.current
      if (f.study && job.study !== f.study) return
      if (f.run && job.run && job.run !== f.run) return
      refetchRef.current()
    })
  }, [bus])
}
