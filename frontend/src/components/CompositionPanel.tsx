// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { DataTable } from './DataTable'
import { PlotlyChart } from './PlotlyChart'
import { useToast } from './Toast'
import { SOURCES } from './annotationShared'
import type {
  AnnotationSource, CategorySet, ColFilter, CompositionBuildResult,
  TableMeta, TableQuery,
} from '../api/types'

type BuildStatus = 'idle' | 'building' | 'ready' | 'error'

export function CompositionPanel({
  study, run, group, subgroups,
}: {
  study: string
  run: string
  group?: string
  subgroups?: string[]
}) {
  const toast = useToast()

  // Source & category set selection
  const [source, setSource] = useState<AnnotationSource>('VSEARCH')
  const [categorySets, setCategorySets] = useState<CategorySet[]>([])
  const [selectedCatSet, setSelectedCatSet] = useState<string>('default')
  const [tables, setTables] = useState<TableMeta[]>([])
  const [selectedTable, setSelectedTable] = useState<string>('merged')

  // Build state
  const [buildStatus, setBuildStatus] = useState<BuildStatus>('idle')
  const [buildResult, setBuildResult] = useState<CompositionBuildResult | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  // Quality filter: max unresolved _X count. -1 = disabled.
  const [maxX, setMaxX] = useState(-1)

  // Analysis
  const [compositionFig, setCompositionFig] = useState<unknown>(null)
  const [analysisLoading, setAnalysisLoading] = useState(false)

  // Subgroup filter for analysis
  const [selectedSubgroup, setSelectedSubgroup] = useState<string | null>(null)

  // Category names + colours from the selected set
  const activeCatSet = useMemo(
    () => categorySets.find(cs => cs.name === selectedCatSet) ?? null,
    [categorySets, selectedCatSet],
  )
  const categoryColourMap = useMemo(() => {
    const map: Record<string, string> = { Other: '#95a5a6' }
    for (const c of activeCatSet?.categories ?? []) {
      if (c.colour) map[c.name] = c.colour
    }
    return map
  }, [activeCatSet])

  // Fetch category sets and tables on mount / source change
  useEffect(() => {
    api.composition.categorySets().then(setCategorySets).catch(() => {})
  }, [])

  useEffect(() => {
    api.results.runTables(study, run, group).then(t => {
      setTables(t)
      if (t.length > 0 && !t.find(x => x.id === selectedTable)) {
        setSelectedTable(t[0].id)
      }
    }).catch(() => {})
  }, [study, run, group, selectedTable])

  // Reset build state when source/table/catset changes
  useEffect(() => {
    setBuildStatus('idle')
    setBuildResult(null)
    setCompositionFig(null)
  }, [source, selectedTable, selectedCatSet])

  // Build composition table
  const handleBuild = useCallback(async () => {
    setBuildStatus('building')
    setErrorMsg(null)
    setCompositionFig(null)
    try {
      const result = await api.composition.build(
        study, run, source, selectedTable, selectedCatSet,
        { maxX }, group,
      )
      setBuildResult(result)
      setBuildStatus('ready')
    } catch (err) {
      setBuildStatus('error')
      setErrorMsg(errorMessage(err))
      toast.error('Failed to build composition table')
    }
  }, [study, run, source, selectedTable, selectedCatSet, maxX, group, toast])

  // Paginated query fetcher
  const fetcher = useCallback(
    (q: TableQuery) => api.composition.query(study, run, source, q, group),
    [study, run, source, group],
  )

  const distinctFetcher = useCallback(
    (column: string, activeFilters?: Record<string, ColFilter>) =>
      api.composition.distinct(study, run, source, column, activeFilters, group),
    [study, run, source, group],
  )

  // Composition analysis chart
  const handleAnalysis = useCallback(async () => {
    setAnalysisLoading(true)
    try {
      const fig = await api.composition.analysis(
        study, run, source, selectedCatSet,
        selectedSubgroup ?? undefined, group,
      )
      setCompositionFig(fig)
    } catch (err) {
      toast.error(errorMessage(err, 'Composition analysis failed'))
    } finally {
      setAnalysisLoading(false)
    }
  }, [study, run, source, selectedCatSet, selectedSubgroup, group, toast])

  return (
    <div className="card">
      {/* Source tabs */}
      <div className="tabs" style={{ marginBottom: 12 }}>
        {SOURCES.map(s => (
          <button
            key={s}
            className={`tab ${source === s ? 'active' : ''}`}
            onClick={() => setSource(s)}
          >
            {s}
          </button>
        ))}
      </div>

      {/* Controls row */}
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 12, flexWrap: 'wrap' }}>
        {/* Table selector */}
        <label style={{ fontWeight: 600, fontSize: '.85rem' }}>Table:</label>
        <select
          value={selectedTable}
          onChange={e => setSelectedTable(e.target.value)}
          disabled={buildStatus === 'building'}
          style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)' }}
        >
          {tables.map(t => (
            <option key={t.id} value={t.id}>{t.label} ({t.rows} rows)</option>
          ))}
        </select>

        {/* Category set selector */}
        <label style={{ fontWeight: 600, fontSize: '.85rem' }}>Categories:</label>
        <select
          value={selectedCatSet}
          onChange={e => setSelectedCatSet(e.target.value)}
          disabled={buildStatus === 'building'}
          style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)' }}
        >
          {categorySets.map(cs => (
            <option key={cs.name} value={cs.name}>{cs.label}</option>
          ))}
        </select>

        {/* Quality filter: -1 = off, 0+ = max unresolved _X count */}
        <label style={{ fontSize: '.82rem', display: 'flex', alignItems: 'center', gap: 4 }}
               title="Max unresolved _X placeholders allowed (-1 = no limit)">
          Max X:
          <input
            type="number" min={-1} max={10} value={maxX}
            onChange={e => setMaxX(parseInt(e.target.value) ?? -1)}
            style={{ width: 48, padding: '3px 6px', borderRadius: 4,
                     border: '1px solid var(--color-border)', fontSize: '.82rem' }}
          />
        </label>

        {/* Build button */}
        <button
          className="btn btn-primary"
          onClick={handleBuild}
          disabled={buildStatus === 'building'}
        >
          {buildStatus === 'building' ? 'Building...' : buildStatus === 'ready' ? 'Rebuild' : 'Build'}
        </button>

        {buildStatus === 'building' && (
          <span style={{ fontSize: '.85rem', color: 'var(--color-muted-fg)' }}>Building composed view...</span>
        )}
      </div>

      {/* Error display */}
      {buildStatus === 'error' && errorMsg && (
        <div style={{
          padding: '8px 12px', marginBottom: 12, borderRadius: 4,
          background: '#fee2e2', color: '#991b1b', fontSize: '.85rem',
          border: '1px solid #fca5a5',
        }}>
          {errorMsg}
        </div>
      )}

      {/* Category summary table */}
      {buildResult && buildStatus === 'ready' && (
        <div style={{ marginBottom: 12, overflowX: 'auto' }}>
          <table style={{ borderCollapse: 'collapse', fontSize: '.82rem', width: '100%', maxWidth: 600 }}>
            <thead>
              <tr style={{ borderBottom: '2px solid var(--color-border)' }}>
                <th style={{ textAlign: 'left', padding: '4px 10px' }}>Category</th>
                <th style={{ textAlign: 'right', padding: '4px 10px' }}>Rows</th>
                <th style={{ textAlign: 'right', padding: '4px 10px' }}>Reads</th>
                <th style={{ textAlign: 'right', padding: '4px 10px' }}>%</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(buildResult.categories).map(([name, stats]) => (
                <tr key={name} style={{ borderBottom: '1px solid var(--color-border)' }}>
                  <td style={{ padding: '3px 10px', fontWeight: 600, color: categoryColourMap[name] ?? 'var(--color-fg)' }}>
                    {name}
                  </td>
                  <td style={{ padding: '3px 10px', textAlign: 'right' }}>{stats.rows.toLocaleString()}</td>
                  <td style={{ padding: '3px 10px', textAlign: 'right' }}>{stats.reads.toLocaleString()}</td>
                  <td style={{ padding: '3px 10px', textAlign: 'right' }}>{stats.reads_percent.toFixed(2)}%</td>
                </tr>
              ))}
              <tr style={{ borderTop: '2px solid var(--color-border)', fontWeight: 600 }}>
                <td style={{ padding: '3px 10px' }}>Total</td>
                <td style={{ padding: '3px 10px', textAlign: 'right' }}>{buildResult.total_rows.toLocaleString()}</td>
                <td style={{ padding: '3px 10px', textAlign: 'right' }}>{buildResult.total_reads.toLocaleString()}</td>
                <td style={{ padding: '3px 10px', textAlign: 'right' }}>100%</td>
              </tr>
            </tbody>
          </table>
        </div>
      )}

      {/* Data table */}
      {buildStatus === 'ready' && (
        <>
          <DataTable
            key={`comp-${source}-${selectedTable}-${selectedCatSet}`}
            storageKey={`comp:${study}/${run}/${group ?? ''}/${source}/${selectedCatSet}`}
            fetcher={fetcher}
            distinctFetcher={distinctFetcher}
          />

          {/* Analysis */}
          <div style={{ marginTop: 24 }}>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              {subgroups && subgroups.length >= 2 && (
                <select
                  value={selectedSubgroup ?? ''}
                  onChange={e => setSelectedSubgroup(e.target.value || null)}
                  style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)',
                           fontSize: '.82rem', background: 'var(--color-bg)' }}
                >
                  <option value="">All sub-groups</option>
                  {subgroups.map(sg => <option key={sg} value={sg}>{sg}</option>)}
                </select>
              )}
              <button
                className="btn btn-primary"
                onClick={handleAnalysis}
                disabled={analysisLoading}
              >
                {analysisLoading ? 'Computing...' : 'Show Composition'}
              </button>
            </div>

            {compositionFig != null && (
              <div style={{ marginTop: 12 }}>
                <PlotlyChart figure={compositionFig} heightRatio={0.3} />
              </div>
            )}
          </div>
        </>
      )}
    </div>
  )
}
