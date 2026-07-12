// (c) 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from 'react'
import { api } from '../api/client'
import { applyChartCosmetics } from '../api/figureColours'
import { PlotlyChart } from './PlotlyChart'
import type { ChartCosmetics } from '../api/types'

const ChartEditorInner = lazy(() => import('./ChartEditorInner'))

// Cosmetic trace keys we persist (never x/y or data).
const TRACE_COSMETIC_KEYS = ['marker', 'line', 'opacity', 'width', 'fillcolor', 'fill', 'mode', 'orientation']

function extractCosmetics(data: unknown[], layout: Record<string, unknown>): ChartCosmetics {
  const traces: Record<string, Record<string, unknown>> = {}
  for (const trace of data) {
    if (!trace || typeof trace !== 'object') continue
    const t = trace as Record<string, unknown>
    const name = t.name as string | undefined
    if (!name) continue
    const picked: Record<string, unknown> = {}
    for (const k of TRACE_COSMETIC_KEYS) if (k in t) picked[k] = t[k]
    if (Object.keys(picked).length) traces[name] = picked
  }
  return { layout, traces }
}

export function ChartCustomiser({ study, chartType, figure, heightRatio }: {
  study: string
  chartType: string
  figure: unknown
  heightRatio?: number
}) {
  const [cosmetics, setCosmetics] = useState<ChartCosmetics>({})
  const [editing, setEditing] = useState(false)
  const patchTimer = useRef<number | undefined>(undefined)

  useEffect(() => () => { if (patchTimer.current) window.clearTimeout(patchTimer.current) }, [])

  const refetch = () => {
    api.chartCosmetics.get(study)
      .then(m => setCosmetics(m[chartType] ?? {}))
      .catch(() => {})
  }
  useEffect(refetch, [study, chartType])

  const styled = useMemo(() => applyChartCosmetics(figure, cosmetics), [figure, cosmetics])

  // Editor seed: the styled figure split into data/layout/frames.
  const seed = useMemo(() => {
    const s = styled as { data?: unknown[]; layout?: Record<string, unknown> }
    return { data: (s?.data ?? []) as unknown[], layout: (s?.layout ?? {}) as Record<string, unknown>, frames: [] as unknown[] }
  }, [styled])

  if (editing) {
    return (
      <div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
          <button className="btn btn-primary" onClick={() => setEditing(false)}>Done</button>
          <button className="btn" onClick={() => {
            api.chartCosmetics.patch(study, { chart_type: chartType, clear: true })
              .then(() => { setEditing(false); refetch() }).catch(() => {})
          }}>Reset cosmetics</button>
        </div>
        <div style={{ height: 'calc(100vh - 220px)', minHeight: 420 }}>
          <Suspense fallback={<div style={{ padding: 24 }}>Loading editor...</div>}>
            <ChartEditorInner
              state={seed}
              onUpdate={(data, layout) => {
                const cos = extractCosmetics(data, layout)
                setCosmetics(cos)
                if (patchTimer.current) window.clearTimeout(patchTimer.current)
                patchTimer.current = window.setTimeout(() => {
                  api.chartCosmetics.patch(study, { chart_type: chartType, layout: cos.layout, traces: cos.traces }).catch(() => {})
                }, 300)
              }}
            />
          </Suspense>
        </div>
      </div>
    )
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 4 }}>
        <button className="btn" style={{ fontSize: '.78rem' }} onClick={() => setEditing(true)}>Customise</button>
      </div>
      <PlotlyChart figure={styled} heightRatio={heightRatio} />
    </div>
  )
}
