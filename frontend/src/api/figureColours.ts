// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

//## Figure recolouring
// Return a shallow clone of a Plotly figure with each trace whose `name`
// matches an entry in `colourMap` recoloured (marker and line), leaving the
// original untouched. Unknown shapes pass through unchanged.
export function applyColourOverrides(figure: unknown, colourMap: Record<string, string>): unknown {
  if (figure == null || typeof figure !== 'object') return figure
  const spec = figure as { data?: unknown[]; layout?: unknown }
  if (!Array.isArray(spec.data)) return figure
  const data = spec.data.map(trace => {
    if (!trace || typeof trace !== 'object') return trace
    const t = trace as { name?: string; marker?: Record<string, unknown>; line?: Record<string, unknown> }
    const colour = t.name != null ? colourMap[t.name] : undefined
    if (!colour) return trace
    return {
      ...t,
      marker: { ...(t.marker ?? {}), color: colour },
      ...(t.line ? { line: { ...t.line, color: colour } } : {}),
    }
  })
  return { ...spec, data }
}

//## Chart cosmetics
// Deep-merge a plain object source onto a target, returning a new object.
function deepMerge(target: Record<string, unknown>, source: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...target }
  for (const [k, v] of Object.entries(source)) {
    const prev = out[k]
    out[k] = (v && typeof v === 'object' && !Array.isArray(v) &&
              prev && typeof prev === 'object' && !Array.isArray(prev))
      ? deepMerge(prev as Record<string, unknown>, v as Record<string, unknown>)
      : v
  }
  return out
}

// Apply persisted cosmetics (layout overrides + name-keyed trace style) onto a
// freshly computed figure, leaving the original untouched.
export function applyChartCosmetics(
  figure: unknown,
  cosmetics: { layout?: Record<string, unknown>; traces?: Record<string, Record<string, unknown>> },
): unknown {
  if (figure == null || typeof figure !== 'object') return figure
  const spec = figure as { data?: unknown[]; layout?: Record<string, unknown> }
  const layout = cosmetics.layout
    ? deepMerge((spec.layout ?? {}) as Record<string, unknown>, cosmetics.layout)
    : { ...(spec.layout ?? {}) }
  const traceOverrides = cosmetics.traces ?? {}
  const data = Array.isArray(spec.data)
    ? spec.data.map(trace => {
        if (!trace || typeof trace !== 'object') return trace
        const t = trace as { name?: string }
        const ov = t.name != null ? traceOverrides[t.name] : undefined
        return ov ? deepMerge(t as Record<string, unknown>, ov) : trace
      })
    : spec.data
  return { ...spec, data, layout }
}
