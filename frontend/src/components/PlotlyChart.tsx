import { useEffect, useRef, useState } from 'react'
import Plotly, { type Data, type Layout } from 'plotly.js-dist-min'

interface PlotlySpec {
  data:   Data[]
  layout: Partial<Layout>
}

interface Props {
  figure: unknown
  className?: string
  /** Height as a ratio of container width (default 0.6). */
  heightRatio?: number
}

export function PlotlyChart({ figure, className, heightRatio = 0.6 }: Props) {
  const wrapRef = useRef<HTMLDivElement>(null)
  const plotRef = useRef<HTMLDivElement>(null)
  const ready   = useRef(false)
  const hasInitialized = useRef(false)
  const [dims, setDims] = useState<{ w: number; h: number } | null>(null)

  useEffect(() => {
    const wrap = wrapRef.current
    const plot = plotRef.current
    if (!wrap || !plot || !figure) return
    const spec = figure as PlotlySpec
    const data = (spec.data ?? []).map((t: Record<string, unknown>) =>
      t.type === 'box' && t.width == null ? { ...t, width: 0.9 } : t
    )
    Plotly.react(plot, data as Data[], {
      autosize: true,
      height: wrap.clientHeight,
      width:  wrap.clientWidth,
      margin: { l: 60, r: 30, t: 40, b: 50 },
      ...spec.layout,
      font:   { size: 16, ...(spec.layout?.font   as object | undefined) },
      legend: { font: { size: 20 }, ...(spec.layout?.legend as object | undefined) },
    }, { responsive: true, displaylogo: false })
    ready.current = true

    // Capture initial pixel dims once, so the inputs appear with real values.
    if (!hasInitialized.current && wrap.clientWidth > 0 && wrap.clientHeight > 0) {
      setDims({ w: wrap.clientWidth, h: wrap.clientHeight })
      hasInitialized.current = true
    }

    return () => { ready.current = false; plot && Plotly.purge(plot) }
  }, [figure, heightRatio])

  // Keep Plotly in sync when the user drags the resize handle or the window changes.
  // Also mirror the live pixel dimensions back into the inputs.
  useEffect(() => {
    const wrap = wrapRef.current
    const plot = plotRef.current
    if (!wrap || !plot) return
    const ro = new ResizeObserver(() => {
      if (!ready.current) return
      const w = wrap.clientWidth
      const h = wrap.clientHeight
      Plotly.relayout(plot, { height: h, width: w })
      setDims(prev => (prev?.w === w && prev?.h === h) ? prev : { w, h })
    })
    ro.observe(wrap)
    return () => ro.disconnect()
  }, [])

  function applyDims(w: number, h: number) {
    if (!Number.isFinite(w) || !Number.isFinite(h) || w < 1 || h < 1) return
    const wrap = wrapRef.current
    if (!wrap) return
    wrap.style.width  = `${w}px`
    wrap.style.height = `${h}px`
    setDims({ w, h })
  }

  const inputStyle: React.CSSProperties = {
    width: 70, marginLeft: 4, padding: '2px 4px',
    borderRadius: 3, border: '1px solid var(--color-border)',
    fontSize: 'inherit', background: 'var(--color-bg)',
    color: 'var(--color-fg)',
  }

  return (
    <div style={{ overflowX: 'auto' }}>
      <div
        ref={wrapRef}
        className={className}
        style={{
          width: '100%',
          aspectRatio: `${1 / heightRatio}`,
          resize: 'both',
          overflow: 'hidden',
          minHeight: 120,
          minWidth: 300,
        }}
      >
        <div ref={plotRef} style={{ width: '100%', height: '100%' }} />
      </div>
      {dims && (
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginTop: 4,
                      fontSize: '.75rem', color: 'var(--color-muted-fg)' }}>
          <label>
            W (px)
            <input
              type="number" min={300} step={10} value={dims.w}
              onChange={e => applyDims(Number(e.target.value), dims.h)}
              style={inputStyle}
            />
          </label>
          <label>
            H (px)
            <input
              type="number" min={120} step={10} value={dims.h}
              onChange={e => applyDims(dims.w, Number(e.target.value))}
              style={inputStyle}
            />
          </label>
        </div>
      )}
    </div>
  )
}
