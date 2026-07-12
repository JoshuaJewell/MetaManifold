/** Alpha diversity metric filter for Plotly figures.
 *
 * The backend always returns a 3-panel figure (Richness, Shannon, Simpson).
 * This utility filters traces and rebuilds the layout to show only selected metrics.
 */

import { useMemo, useState } from 'react'

export const ALPHA_METRICS = ['richness', 'shannon', 'simpson'] as const
export type AlphaMetric = (typeof ALPHA_METRICS)[number]

export const METRIC_LABELS: Record<AlphaMetric, string> = {
  richness: 'Richness',
  shannon:  'Shannon',
  simpson:  'Simpson',
}

/** Map each metric to its backend axis suffix (panel index). */
const METRIC_YAXIS: Record<AlphaMetric, string> = {
  richness: 'y',
  shannon:  'y2',
  simpson:  'y3',
}

interface PlotlyTrace {
  yaxis?: string
  xaxis?: string
  [k: string]: unknown
}

interface PlotlyFigure {
  data: PlotlyTrace[]
  layout: Record<string, unknown>
}

/** Filter a 3-panel alpha figure to only the selected metrics, renumbering axes.
 *
 * Deep-clones the figure first because Plotly.react mutates trace objects in place,
 * adding internal properties (uid, _input, etc.) that break axis remapping if reused.
 */
export function filterAlphaFigure(
  figure: unknown,
  selected: Set<AlphaMetric>,
): unknown {
  if (!figure || selected.size === ALPHA_METRICS.length) return figure
  const raw = figure as PlotlyFigure
  if (!raw.data || !raw.layout) return figure

  // Deep clone to strip Plotly-internal state from any prior render
  const fig = JSON.parse(JSON.stringify(raw)) as PlotlyFigure

  // Determine which panels to keep (in original order)
  const kept = ALPHA_METRICS.filter(m => selected.has(m))
  if (kept.length === 0) return figure

  // Build old-axis to new-axis mapping
  const axisMap = new Map<string, { y: string; x: string }>()
  kept.forEach((metric, i) => {
    const suffix = i === 0 ? '' : String(i + 1)
    axisMap.set(METRIC_YAXIS[metric], {
      y: `y${suffix}`,
      x: `x${suffix}`,
    })
  })

  // Filter and remap traces
  const data = fig.data
    .filter(t => {
      const ya = t.yaxis ?? 'y'
      return axisMap.has(ya)
    })
    .map(t => {
      const ya = t.yaxis ?? 'y'
      const mapped = axisMap.get(ya)!
      return { ...t, yaxis: mapped.y, xaxis: mapped.x }
    })

  // Build new layout: copy non-axis keys, then remap axis configs
  const layout: Record<string, unknown> = {}
  for (const [key, val] of Object.entries(fig.layout)) {
    if (/^[xy]axis\d*$/.test(key)) continue // skip old axes
    layout[key] = val
  }

  // Add remapped axis configs
  for (const [oldY, { y, x }] of axisMap) {
    const oldX = oldY === 'y' ? 'x' : `x${oldY.slice(1)}`
    const yLayoutKey = y === 'y' ? 'yaxis' : `yaxis${y.slice(1)}`
    const xLayoutKey = x === 'x' ? 'xaxis' : `xaxis${x.slice(1)}`
    const oldYLayoutKey = oldY === 'y' ? 'yaxis' : `yaxis${oldY.slice(1)}`
    const oldXLayoutKey = oldX === 'x' ? 'xaxis' : `xaxis${oldX.slice(1)}`
    layout[yLayoutKey] = fig.layout[oldYLayoutKey] ?? {}
    layout[xLayoutKey] = fig.layout[oldXLayoutKey] ?? {}
  }

  // Update grid rows
  layout['grid'] = { rows: kept.length, columns: 1, pattern: 'independent' }

  return { data, layout }
}

/** Map each metric to the source figure's y-axis layout key. */
const METRIC_SRC_YLAYOUT: Record<AlphaMetric, string> = {
  richness: 'yaxis',
  shannon:  'yaxis2',
  simpson:  'yaxis3',
}

/** Read a Plotly title's text, tolerating both the bare-string and {text} forms. */
function titleText(t: unknown): string | undefined {
  if (typeof t === 'string') return t
  if (t && typeof t === 'object' && typeof (t as { text?: unknown }).text === 'string') {
    return (t as { text: string }).text
  }
  return undefined
}

/** Isolate a single alpha metric as a standalone single-panel figure, titled by
 *  that metric. Each pane then carries its own single axis, so the cosmetics
 *  editor styles it without any subplot selectors. */
export function extractAlphaPanel(figure: unknown, metric: AlphaMetric): unknown {
  if (!figure || typeof figure !== 'object') return figure
  const raw = figure as PlotlyFigure
  if (!raw.data || !raw.layout) return figure
  // Recover the metric's full name from its source y-axis title before filtering.
  const srcAxis = raw.layout[METRIC_SRC_YLAYOUT[metric]] as { title?: unknown } | undefined
  const name = (srcAxis && titleText(srcAxis.title)) ?? METRIC_LABELS[metric]
  const single = filterAlphaFigure(figure, new Set<AlphaMetric>([metric])) as PlotlyFigure
  const layout: Record<string, unknown> = { ...single.layout, title: { text: name } }
  // The chart title now carries the metric name; clear the redundant y-axis title.
  const yaxis = layout['yaxis']
  if (yaxis && typeof yaxis === 'object') {
    layout['yaxis'] = { ...(yaxis as Record<string, unknown>), title: { text: '' } }
  }
  return { data: single.data, layout }
}

/** Stateful alpha-metric selection: holds the selected set and keeps at least
 *  one metric active. */
export function useAlphaMetricSelection() {
  const [metrics, setMetrics] = useState<Set<AlphaMetric>>(() => new Set(ALPHA_METRICS))

  const toggle = (m: AlphaMetric) =>
    setMetrics(prev => {
      const next = new Set(prev)
      if (next.has(m)) { if (next.size > 1) next.delete(m) }
      else next.add(m)
      return next
    })

  return { metrics, toggle }
}

/** As useAlphaMetricSelection, additionally returning the figure filtered to the
 *  current selection. */
export function useAlphaMetricFilter(figure: unknown) {
  const { metrics, toggle } = useAlphaMetricSelection()

  const filtered = useMemo(
    () => filterAlphaFigure(figure, metrics),
    [figure, metrics],
  )

  return { filtered, metrics, toggle }
}

/** Checkbox row driving an alpha-metric selection from useAlphaMetricFilter. */
export function AlphaMetricToggles({ metrics, toggle }: {
  metrics: Set<AlphaMetric>
  toggle: (m: AlphaMetric) => void
}) {
  return (
    <div style={{ display: 'flex', gap: 10, marginBottom: 8, fontSize: '.82rem' }}>
      {ALPHA_METRICS.map(m => (
        <label key={m} style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
          <input type="checkbox" checked={metrics.has(m)} onChange={() => toggle(m)} />
          {METRIC_LABELS[m]}
        </label>
      ))}
    </div>
  )
}
