import { useEffect, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { PlotlyChart } from './PlotlyChart'
import { useToast } from './Toast'
import { discoverAnnotationOptions, type AnalysisOption } from './annotationShared'
import type { ComparisonRunSpec, ColFilter, PermanovaResult } from '../api/types'

export function ComparisonPanel({ study, runs }: {
  study: string
  runs: ComparisonRunSpec[]
}) {
  const toast = useToast()
  const [alphaFig, setAlphaFig]       = useState<unknown>(null)
  const [nmdsFig, setNmdsFig]         = useState<unknown>(null)
  const [permanova, setPermanova]     = useState<PermanovaResult | null>(null)
  const [loading, setLoading]         = useState<string | null>(null)
  const [options, setOptions]         = useState<AnalysisOption[]>([])
  const [analysisKey, setAnalysisKey] = useState<string | null>(null)
  const [rAvailable, setRAvailable]   = useState<boolean | null>(null)

  useEffect(() => {
    api.analysis.capabilities().then(c => setRAvailable(c.r_available)).catch(() => setRAvailable(false))
  }, [])

  const isSubgroupMode = runs.length > 0 && runs.every(r => r.prefix)

  // Discover annotated source/table pairs available across all selected runs.
  useEffect(() => {
    let cancelled = false
    const seen = new Set<string>()
    const unique = runs.filter(r => {
      const key = `${r.run}|${r.group ?? ''}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
    Promise.all(unique.map(r => discoverAnnotationOptions(study, r.run, r.group)))
      .then(results => {
        if (cancelled) return
        // Intersect: keep only options present in ALL runs
        const shared = new Map<string, AnalysisOption>()
        results.forEach((opts, index) => {
          const keys = new Set(opts.map(o => o.key))
          if (index === 0) {
            for (const o of opts) shared.set(o.key, o)
          } else {
            for (const key of [...shared.keys()]) {
              if (!keys.has(key)) shared.delete(key)
            }
          }
        })
        const sorted = [...shared.values()].sort((a, b) =>
          a.table !== b.table ? a.table.localeCompare(b.table) : a.source.localeCompare(b.source))
        setOptions(sorted)
        setAnalysisKey(current => current && sorted.some(o => o.key === current) ? current : sorted[0]?.key ?? null)
      })
    return () => { cancelled = true }
  }, [study, runs])

  const selected = options.find(option => option.key === analysisKey) ?? null
  const body = selected ? { table: selected.table, source: selected.source, runs: runs.map(run => ({ ...run, source: selected.source })), colFilters: {} as Record<string, ColFilter> } : null

  const run = async (type: 'alpha' | 'nmds' | 'permanova') => {
    if (!body) return
    setLoading(type)
    try {
      if (type === 'alpha') {
        setAlphaFig(await api.analysis.compareAlpha(study, body))
      } else if (type === 'nmds') {
        setNmdsFig(await api.analysis.nmds(study, body))
      } else {
        setPermanova(await api.analysis.permanova(study, body))
      }
    } catch (err) {
      toast.error(`${type} failed: ${errorMessage(err)}`)
    } finally {
      setLoading(null)
    }
  }

  if (runs.length < 2) return null

  return (
    <div style={{ marginTop: 24 }}>
      <h2 style={{ fontSize: '1rem', marginBottom: 8 }}>
        {isSubgroupMode ? 'Cross-Group Comparison' : 'Cross-Run Comparison'}
      </h2>
      <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)', marginBottom: 12 }}>
        Comparing {runs.length} {isSubgroupMode ? 'groups' : 'runs'} on the{' '}
        {options.length > 1 ? (
          <select
            value={analysisKey ?? ''}
            onChange={e => setAnalysisKey(e.target.value)}
            style={{ font: 'inherit', padding: '1px 4px', verticalAlign: 'baseline' }}
          >
            {options.map(option => <option key={option.key} value={option.key}>{option.label}</option>)}
          </select>
        ) : options.length === 1 ? (
          <code>{options[0].label}</code>
        ) : (
          <span>no shared annotated table</span>
        )}
        {' '}dataset
      </p>
      <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
        <button className="btn" onClick={() => run('alpha')} disabled={loading !== null || !body}>
          {loading === 'alpha' ? 'Computing...' : 'Alpha Comparison'}
        </button>
        {rAvailable && (
          <button className="btn" onClick={() => run('nmds')} disabled={loading !== null || !body}>
            {loading === 'nmds' ? 'Computing...' : 'NMDS'}
          </button>
        )}
        {rAvailable && (
          <button className="btn" onClick={() => run('permanova')} disabled={loading !== null || !body}>
            {loading === 'permanova' ? 'Computing...' : 'PERMANOVA'}
          </button>
        )}
      </div>

      {alphaFig != null && <PlotlyChart figure={alphaFig} heightRatio={0.48} />}
      {nmdsFig != null && <PlotlyChart figure={nmdsFig} heightRatio={0.48} />}
      {permanova && (
        <div className="card" style={{ fontFamily: 'monospace', fontSize: '.82rem', whiteSpace: 'pre-wrap' }}>
          <div className="card-title">PERMANOVA Results</div>
          <pre style={{ margin: 0 }}>{permanova.text}</pre>
          {permanova.p_value != null && (
            <p style={{ marginTop: 8, fontFamily: 'inherit' }}>
              R&sup2; = {permanova.r2?.toFixed(3)} | F = {permanova.f_statistic?.toFixed(2)} | p = {permanova.p_value?.toFixed(4)}
            </p>
          )}
        </div>
      )}
    </div>
  )
}
