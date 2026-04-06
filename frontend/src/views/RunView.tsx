import { useState, useCallback, useEffect, useRef, useMemo } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useApi } from '../hooks/useApi'
import { useAnalysis } from '../hooks/useAnalysis'
import { useJobRefetch, useSSEConnected } from '../hooks/useJobEvents'
import { api, apiUrl } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { PipelineStages, StageConfig } from '../components/PipelineStages'
import { AnalysisControls } from '../components/AnalysisControls'
import { PlotlyChart } from '../components/PlotlyChart'
import { DataTable } from '../components/DataTable'
import { Skeleton } from '../components/Skeleton'
import { useToast } from '../components/Toast'
import { NameDialog } from '../components/NameDialog'
import { ComparisonPanel } from '../components/ComparisonPanel'
import { AnnotationPanel } from '../components/AnnotationPanel'
import { CompositionPanel } from '../components/CompositionPanel'
import type { TableMeta, TableQuery, ColFilter, FilterPreset, ConfigMap, RunStages } from '../api/types'
import type { RowPopupData, TableStats } from '../components/DataTable'
import { discoverAnnotationOptions, type AnalysisOption } from '../components/annotationShared'

type Tab = 'pipeline' | 'qc' | 'dada2' | 'tables' | 'annotation' | 'composition'

// Maps tabs to the backend stages whose staleness should show a yellow dot
const TAB_STALE_STAGES: Partial<Record<Tab, string[]>> = {
  qc:    ['fastqc'],
  dada2: ['dada2_denoise', 'dada2_classify'],
}

export function RunView({ runName }: { runName?: string } = {}) {
  const { study, run: runParam, group } = useParams<{ study: string; run?: string; group?: string }>()
  const run = runName ?? runParam
  const navigate = useNavigate()
  const toast    = useToast()
  const [tab, setTab]  = useState<Tab>('pipeline')
  const [renaming, setRenaming] = useState(false)

  const runFetcher = useCallback(() => api.runs.get(study!, run!, group), [study, run, group])
  const { data: runData, loading, error, refetch } = useApi(runFetcher)

  const tablesFetcher = useCallback(() => api.results.runTables(study!, run!, group), [study, run, group])
  const { data: tables, refetch: refetchTables } = useApi(tablesFetcher)

  const qcFetcher = useCallback(() => api.results.qcOutputs(study!, run!, group), [study, run, group])
  const { data: qcData, refetch: refetchQc } = useApi(qcFetcher)

  const dada2Fetcher = useCallback(() => api.results.dada2Outputs(study!, run!, group), [study, run, group])
  const { data: dada2Data, refetch: refetchDada2 } = useApi(dada2Fetcher)

  const configFetcher = useCallback(() => api.config.getRun(study!, run!, group), [study, run, group])
  const { data: configMap, refetch: refetchConfig } = useApi(configFetcher)

  const refetchOutputs = useCallback(() => {
    refetch()
    refetchTables()
    refetchQc()
    refetchDada2()
  }, [refetch, refetchTables, refetchQc, refetchDada2])

  const handleConfigChanged = useCallback(() => {
    refetchConfig()
    refetch()
  }, [refetchConfig, refetch])

  const jobFilter = useMemo(() => ({ study: study!, run: run! }), [study, run])
  useJobRefetch(refetchOutputs, jobFilter)

  // Polling fallback only when SSE is disconnected and a stage is running
  const sseConnected = useSSEConnected()
  const hasRunning = runData
    ? Object.values(runData.stages ?? {}).some(s => (s as { status: string }).status === 'running')
    : false
  useEffect(() => {
    if (!hasRunning || sseConnected) return
    const id = setInterval(refetchOutputs, 3000)
    return () => clearInterval(id)
  }, [hasRunning, sseConnected, refetchOutputs])

  const handleRunStage = async (stage: string) => {
    await api.pipeline.runStage(study!, run!, stage, group)
    refetchOutputs()
  }

  const handleRunAll = async () => {
    await api.pipeline.runRun(study!, run!, group)
    refetchOutputs()
  }

  const handleRename = async (newName: string) => {
    await api.runs.rename(study!, run!, newName, group)
    setRenaming(false)
    toast.success(`Renamed to '${newName}'`)
    const basePath = group ? `/${study}/${group}/${newName}` : `/${study}/${newName}`
    navigate(basePath)
  }

  const handleDelete = async () => {
    if (!window.confirm(`Delete run '${run}'? This cannot be undone.`)) return
    await api.runs.delete(study!, run!, group)
    toast.success(`Run '${run}' deleted`)
    navigate(`/${study}`)
  }

  const isTabStale = (t: Tab): boolean => {
    const stages = TAB_STALE_STAGES[t]
    if (!stages || !runData) return false
    return stages.some(s => {
      const info = runData.stages[s as keyof typeof runData.stages]
      return info?.status === 'stale'
    })
  }

  const tablesCacheKey = useMemo(() => {
    if (!runData) return null
    const stages = [
      runData.stages.dada2_denoise,
      runData.stages.dada2_classify,
      runData.stages.swarm,
      runData.stages.vsearch,
      runData.stages.merge_taxa,
    ]
    return stages.map(s => `${s.status}:${s.last_run ?? ''}`).join('|')
  }, [runData])

  return (
    <>
      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <h1>{run}</h1>
          <p>
            {study}
            {runData && ` - ${runData.sample_count} sample${runData.sample_count !== 1 ? 's' : ''}`}
            {runData?.pooled && (
              <span style={{ color: 'var(--color-muted-fg)' }}>
                {' - '}pooling {runData.subgroups.length} sub-group{runData.subgroups.length !== 1 ? 's' : ''}
              </span>
            )}
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, flexShrink: 0 }}>
          <button className="btn" onClick={() => setRenaming(true)}>Rename</button>
          <button className="btn" style={{ color: '#c92a2a', borderColor: '#ffc9c9' }} onClick={handleDelete}>Delete</button>
        </div>
      </div>

      {renaming && (
        <NameDialog
          title="Rename Run"
          initialValue={run}
          placeholder="run-name"
          onConfirm={handleRename}
          onClose={() => setRenaming(false)}
        />
      )}

      <div className="tabs">
        {(['pipeline', 'qc', 'dada2', 'tables', 'annotation', 'composition'] as Tab[]).map(t => {
          const label = t === 'pipeline' ? 'Pipeline'
            : t === 'qc' ? 'QC'
            : t === 'dada2' ? 'DADA2'
            : t === 'tables' ? `Tables (${tables?.length ?? 0})`
            : t === 'annotation' ? 'Annotation'
            : 'Composition'
          const stale = isTabStale(t)
          return (
            <button key={t} className={`tab ${tab === t ? 'active' : ''}`} onClick={() => setTab(t)}>
              {label}
              {stale && <span style={{ display: 'inline-block', width: 7, height: 7, borderRadius: '50%', background: '#f59e0b', marginLeft: 6, verticalAlign: 'middle' }} title="Config changed - re-run to update outputs" />}
            </button>
          )
        })}
      </div>

      {loading && <Skeleton lines={4} />}
      {error   && <p className="error-msg">{error}</p>}

      {tab === 'pipeline' && runData && (
        <>
          <div className="card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
              <div className="card-title">Pipeline Stages</div>
              <button className="btn btn-primary" onClick={handleRunAll}>Run all</button>
            </div>
            <PipelineStages stages={runData.stages} onRun={handleRunStage} configMap={configMap} study={study!} run={run!} group={group} onConfigChanged={handleConfigChanged} />
          </div>
          <PipelineStatsChart study={study!} run={run!} group={group} />
        </>
      )}

      {tab === 'qc' && <QCPanel study={study!} run={run!} group={group} qcData={qcData ?? null} stages={runData?.stages ?? null} onRunStage={handleRunStage} configMap={configMap} cacheKey={runData?.stages?.fastqc?.last_run ?? null} />}
      {tab === 'dada2' && <DADA2Panel study={study!} run={run!} group={group} dada2Data={dada2Data ?? null} configMap={configMap ?? null} onConfigChanged={handleConfigChanged} stages={runData?.stages ?? null} onRunStage={handleRunStage} cacheKey={runData?.stages?.dada2_denoise?.last_run ?? null} />}
      {tab === 'tables' && <TablesPanel study={study!} run={run!} group={group} tables={tables ?? []} onTablesChanged={refetchTables} cacheKey={tablesCacheKey} />}
      {tab === 'annotation' && <AnnotationPanel study={study!} run={run!} group={group} subgroups={runData?.subgroups} />}

      {tab === 'composition' && <CompositionPanel study={study!} run={run!} group={group} subgroups={runData?.subgroups} />}

      {runData?.pooled && runData.subgroups.length >= 2 && (
        <ComparisonPanel
          study={study!}
          runs={runData.subgroups.map(sg => ({ run: run!, group: group ?? null, prefix: sg }))}
        />
      )}
    </>
  )
}

interface QCOutput { has_report: boolean; report_url: string | null }

function QCPanel({ qcData, stages, onRunStage, configMap, cacheKey }: { study: string; run: string; group?: string; qcData: QCOutput | null; stages: RunStages | null; onRunStage: (stage: string) => void; configMap?: ConfigMap | null; cacheKey?: string | null }) {
  const fastqcStatus = stages?.fastqc?.status
  const isStale = fastqcStatus === 'stale'
  const isRunning = fastqcStatus === 'running'

  if (!qcData || !qcData.has_report) {
    return (
      <div className="empty-state">
        <p>No QC report generated yet. Run QC to generate FastQC/MultiQC output on raw reads.</p>
        <button className="btn btn-primary" style={{ marginTop: 12 }} onClick={() => onRunStage('fastqc')} disabled={isRunning}>
          {isRunning ? 'Running...' : 'Run QC'}
        </button>
      </div>
    )
  }

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ padding: '12px 16px', borderBottom: '1px solid var(--color-border)', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div className="card-title" style={{ margin: 0 }}>MultiQC Report</div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {isStale && <StaleKeysBadge staleKeys={stages?.fastqc?.stale_keys ?? []} configMap={configMap} />}
          <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }} onClick={() => onRunStage('fastqc')} disabled={isRunning}>
            {isRunning ? 'Running...' : isStale ? 'Re-run QC' : 'Run QC'}
          </button>
          <a
            href={apiUrl(qcData.report_url!)}
            target="_blank"
            rel="noopener noreferrer"
            className="btn"
            style={{ fontSize: '.78rem', padding: '3px 10px' }}
          >
            Open in new tab
          </a>
        </div>
      </div>
      <iframe
        src={apiUrl(qcData.report_url!) + (cacheKey ? `?v=${encodeURIComponent(cacheKey)}` : '')}
        style={{ width: '100%', height: 'calc(100vh - 240px)', minHeight: 500, border: 'none' }}
        title="MultiQC Report"
      />
    </div>
  )
}

interface DADA2Output {
  figures: { name: string; label: string; url: string }[]
  has_stats: boolean
  logs: { name: string; url: string }[]
  config: Record<string, unknown>
}

type DADA2SubTab = 'quality' | 'denoising' | 'merging' | 'taxonomy'

const DADA2_SUBTABS: { key: DADA2SubTab; label: string; runTarget: string }[] = [
  { key: 'quality',   label: 'Quality & Filtering',  runTarget: 'filter_trim' },
  { key: 'denoising', label: 'Denoising',            runTarget: 'learn_errors' },
  { key: 'merging',   label: 'Merging & Lengths',    runTarget: 'denoise' },
  { key: 'taxonomy',  label: 'Taxonomy',             runTarget: 'assign_taxonomy' },
]

const SUBTAB_FIGURES: Record<DADA2SubTab, string[]> = {
  quality:   ['quality_unfiltered', 'quality_filtered'],
  denoising: ['error_rates'],
  merging:   ['length_distribution', 'length_distribution_filtered'],
  taxonomy:  [],
}

const SUBTAB_CONFIG: Record<DADA2SubTab, { prefix: string; label: string }[]> = {
  quality:   [{ prefix: 'dada2.filter_trim.', label: 'Filter & Trim' }],
  denoising: [{ prefix: 'dada2.dada.', label: 'Denoising' }],
  merging:   [
    { prefix: 'dada2.merge.', label: 'Merge Pairs' },
    { prefix: 'dada2.asv.', label: 'ASV & Chimera Filtering' },
  ],
  taxonomy:  [{ prefix: 'dada2.taxonomy.', label: 'Taxonomy Assignment' }],
}

const SUBTAB_HINTS: Record<DADA2SubTab, string> = {
  quality:   'Inspect pre-filter quality to choose truncation lengths, then verify post-filter output.',
  denoising: 'Error rate convergence plots. Re-run if denoising parameters change.',
  merging:   'Check length distribution to set band-size min/max, then verify filtering removed off-target amplicons.',
  taxonomy:  'Review pipeline stats for unexpected read loss before running taxonomy assignment.',
}

const SUBTAB_STALE_SECTIONS: Record<DADA2SubTab, string[]> = {
  quality:   ['dada2.file_patterns', 'dada2.filter_trim'],
  denoising: ['dada2.dada'],
  merging:   ['dada2.merge', 'dada2.asv'],
  taxonomy:  ['dada2.taxonomy', 'dada2.output'],
}

function isSubTabStale(tab: DADA2SubTab, staleKeys: string[]): boolean {
  if (staleKeys.length === 0) return false
  const sections = SUBTAB_STALE_SECTIONS[tab]
  return sections.some(sec => staleKeys.some(k => k.startsWith(sec)))
}

function StaleKeysBadge({ staleKeys, configMap }: { staleKeys: string[]; configMap?: ConfigMap | null }) {
  if (!Array.isArray(staleKeys) || staleKeys.length === 0) return null

  const lines = staleKeys.map(k => {
    const entry = configMap?.[k]
    if (entry) {
      const v = typeof entry.value === 'object' ? JSON.stringify(entry.value) : String(entry.value)
      return `${k} = ${v} (${entry.source})`
    }
    const matchingKeys = configMap
      ? Object.entries(configMap).filter(([ck]) => ck.startsWith(k + '.'))
      : []
    if (matchingKeys.length > 0) {
      return matchingKeys.map(([ck, { value, source }]) => {
        const v = typeof value === 'object' ? JSON.stringify(value) : String(value)
        return `${ck} = ${v} (${source})`
      }).join('\n')
    }
    return k
  })

  return (
    <span
      style={{ fontSize: '.75rem', color: '#f59e0b', fontWeight: 500, cursor: 'default', position: 'relative' }}
      title={lines.join('\n')}
    >
      Config changed
    </span>
  )
}



function DADA2Panel({ study, run, group, dada2Data, configMap, onConfigChanged, stages, onRunStage, cacheKey }: {
  study: string; run: string; group?: string; dada2Data: DADA2Output | null
  configMap: ConfigMap | null; onConfigChanged: () => void
  stages: RunStages | null; onRunStage: (stage: string) => void
  cacheKey?: string | null
}) {
  const [showStats, setShowStats] = useState(false)
  const [statsData, setStatsData] = useState<{ columns: string[]; rows: Record<string, unknown>[] } | null>(null)
  const [expandedLog, setExpandedLog] = useState<string | null>(null)
  const [logContent, setLogContent] = useState<Record<string, string>>({})

  useEffect(() => {
    setStatsData(null)
    setExpandedLog(null)
    setLogContent({})
  }, [cacheKey])

  // Auto-select earliest stale sub-tab, or default to 'quality'
  const denoiseStaleKeys = stages?.dada2_denoise?.stale_keys ?? []
  const classifyStaleKeys = stages?.dada2_classify?.stale_keys ?? []
  const allStaleKeys = [...denoiseStaleKeys, ...classifyStaleKeys]

  const initialTab = (): DADA2SubTab => {
    for (const { key } of DADA2_SUBTABS) {
      if (isSubTabStale(key, allStaleKeys)) return key
    }
    return 'quality'
  }
  const [subTab, setSubTab] = useState<DADA2SubTab>(initialTab)

  useEffect(() => {
    if (showStats && !statsData) {
      api.results.dada2Stats(study, run, group).then(setStatsData).catch(() => {})
    }
  }, [showStats, statsData, study, run, group])

  const fetchLog = async (url: string, name: string) => {
    if (logContent[name]) { setExpandedLog(expandedLog === name ? null : name); return }
    try {
      const res = await fetch(apiUrl(url))
      const text = await res.text()
      setLogContent(prev => ({ ...prev, [name]: text }))
      setExpandedLog(name)
    } catch {
      setLogContent(prev => ({ ...prev, [name]: 'Failed to load log.' }))
      setExpandedLog(name)
    }
  }

  const denoiseStatus  = stages?.dada2_denoise?.status ?? ''
  const denoiseRunning = denoiseStatus === 'running'
  const classifyStatus = stages?.dada2_classify?.status ?? ''
  const classifyRunning = classifyStatus === 'running'
  const isRunning = denoiseRunning || classifyRunning

  const tabDef = DADA2_SUBTABS.find(t => t.key === subTab)!
  const figNames = SUBTAB_FIGURES[subTab]
  const figures = figNames.map(name => dada2Data?.figures.find(f => f.name === name) ?? null)
  const configSections = SUBTAB_CONFIG[subTab]
  const hint = SUBTAB_HINTS[subTab]
  const tabStale = isSubTabStale(subTab, allStaleKeys)

  return (
    <>
      {/* Sub-tabs */}
      <div className="tabs" style={{ marginBottom: 0 }}>
        {DADA2_SUBTABS.map(t => {
          const stale = isSubTabStale(t.key, allStaleKeys)
          return (
            <button key={t.key} className={`tab ${subTab === t.key ? 'active' : ''}`}
              onClick={() => setSubTab(t.key)}>
              {t.label}
              {stale && <span style={{ display: 'inline-block', width: 7, height: 7, borderRadius: '50%', background: '#f59e0b', marginLeft: 6, verticalAlign: 'middle' }} title="Config changed" />}
            </button>
          )
        })}
      </div>

      {/* Panel content */}
      <div className="card" style={{ borderTopLeftRadius: 0, borderTopRightRadius: 0 }}>
        {/* Figures: side-by-side for pairs, single for solo */}
        {figNames.length > 0 && (
          <div style={{ display: 'flex', gap: 12, marginBottom: 12 }}>
            {figures.map((fig, i) => (
              <div key={figNames[i]} style={{ flex: 1 }}>
                <div style={{ fontSize: '.78rem', fontWeight: 600, color: 'var(--color-muted-fg)', marginBottom: 4 }}>
                  {figNames[i].replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}
                </div>
                {fig ? (
                  <iframe
                    src={apiUrl(fig.url) + (cacheKey ? `?v=${encodeURIComponent(cacheKey)}` : '')}
                    style={{ width: '100%', height: figures.length > 1 ? 'calc(50vh - 120px)' : 'calc(100vh - 380px)', minHeight: 280, border: '1px solid var(--color-border)', borderRadius: 4 }}
                    title={fig.label}
                  />
                ) : (
                  <div style={{ height: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--color-surface)', border: '1px solid var(--color-border)', borderRadius: 4, color: 'var(--color-muted-fg)', fontSize: '.85rem' }}>
                    Not yet generated
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        {/* Taxonomy: pipeline stats instead of figures */}
        {subTab === 'taxonomy' && (
          <>
            <div style={{ fontSize: '.85rem', fontWeight: 600, marginBottom: 8, cursor: dada2Data?.has_stats ? 'pointer' : 'default' }}
              onClick={() => dada2Data?.has_stats && setShowStats(!showStats)}>
              Pipeline Stats
              {dada2Data?.has_stats && (
                <span style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)', marginLeft: 8 }}>{showStats ? 'Hide' : 'Show'}</span>
              )}
            </div>
            {dada2Data?.has_stats && showStats && (
              statsData ? (
                <div style={{ overflowX: 'auto', marginBottom: 12 }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.82rem' }}>
                    <thead>
                      <tr>
                        {statsData.columns.map(c => (
                          <th key={c} style={{ padding: '6px 10px', borderBottom: '2px solid var(--color-border)', textAlign: 'left', whiteSpace: 'nowrap' }}>{c}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {statsData.rows.map((row, i) => (
                        <tr key={i}>
                          {statsData.columns.map(c => (
                            <td key={c} style={{ padding: '4px 10px', borderBottom: '1px solid var(--color-border)', whiteSpace: 'nowrap' }}>
                              {row[c] != null ? String(row[c]) : ''}
                            </td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                    {statsData.rows.length > 1 && (
                      <tfoot>
                        <tr style={{ fontWeight: 600, borderTop: '2px solid var(--color-border)' }}>
                          {statsData.columns.map((c, ci) => {
                            const vals = statsData.rows.map(r => Number(r[c])).filter(v => !isNaN(v))
                            if (vals.length === 0) return <td key={c} style={{ padding: '4px 10px' }}>{ci === 0 ? 'Median' : ''}</td>
                            const sorted = [...vals].sort((a, b) => a - b)
                            const mid = Math.floor(sorted.length / 2)
                            const med = sorted.length % 2 !== 0 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
                            return <td key={c} style={{ padding: '4px 10px', whiteSpace: 'nowrap' }}>{Number.isInteger(med) ? med.toLocaleString() : med.toLocaleString(undefined, { maximumFractionDigits: 1 })}</td>
                          })}
                        </tr>
                      </tfoot>
                    )}
                  </table>
                </div>
              ) : (
                <p className="loading" style={{ marginTop: 8 }}>Loading...</p>
              )
            )}
          </>
        )}

        {/* Hint */}
        <p style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)', fontStyle: 'italic', margin: '8px 0 12px' }}>{hint}</p>

        {/* Config strips */}
        {configMap && configSections.map(sec => (
          <StageConfig
            key={sec.prefix}
            configMap={configMap}
            prefixes={[sec.prefix]}
            study={study}
            run={run}
            group={group}
            onConfigChanged={onConfigChanged}
          />
        ))}

        {/* Actions bar */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 14 }}>
          <div>
            {tabStale && <StaleKeysBadge staleKeys={allStaleKeys} configMap={configMap} />}
          </div>
          <button className="btn btn-primary" onClick={() => onRunStage(tabDef.runTarget)} disabled={isRunning}>
            {isRunning ? 'Running...' : tabStale ? `Re-run ${tabDef.label}` : `Run ${tabDef.label}`}
          </button>
        </div>
      </div>

      {/* Logs (shared across all sub-tabs) */}
      {(dada2Data?.logs.length ?? 0) > 0 && (
        <div className="card">
          <div className="card-title">Stage Logs</div>
          {dada2Data!.logs.map(log => (
            <div key={log.name} style={{ marginBottom: 4 }}>
              <button
                className="btn"
                style={{ fontSize: '.78rem', padding: '3px 10px', width: '100%', textAlign: 'left' }}
                onClick={() => fetchLog(log.url, log.name)}
              >
                {expandedLog === log.name ? 'Hide' : 'Show'} {log.name}
              </button>
              {expandedLog === log.name && logContent[log.name] && (
                <pre style={{
                  margin: '4px 0 8px', padding: 10, background: 'var(--color-bg-alt, #f5f5f5)',
                  border: '1px solid var(--color-border)', borderRadius: 4,
                  fontSize: '.75rem', maxHeight: 300, overflow: 'auto', whiteSpace: 'pre-wrap'
                }}>
                  {logContent[log.name]}
                </pre>
              )}
            </div>
          ))}
        </div>
      )}
    </>
  )
}

function TablesPanel({ study, run, group, tables, onTablesChanged, cacheKey }: { study: string; run: string; group?: string; tables: TableMeta[]; onTablesChanged: () => void; cacheKey?: string | null }) {
  const [selected, setSelected] = useState<string | null>(tables[0]?.id ?? null)

  useEffect(() => {
    if (tables.length > 0 && !tables.some(t => t.id === selected)) {
      setSelected(tables[0].id)
    }
  }, [tables])
  const [filters, setFilters]   = useState<Record<string, ColFilter>>({})
  const [sortBy, setSortBy]     = useState<string | null>(null)
  const [sortDir, setSortDir]   = useState<'asc' | 'desc'>('asc')
  const [filterKey, setFilterKey] = useState(0)
  const [liveStats, setLiveStats] = useState<TableStats | null>(null)
  const [presets, setPresets]     = useState<FilterPreset[]>([])
  const [loadingPreset, setLoadingPreset] = useState(false)
  const [saving, setSaving]       = useState(false)
  const toast = useToast()
  const fileInputRef = useRef<HTMLInputElement>(null)

  const reloadPresets = useCallback(() => { api.presets.list().then(setPresets).catch(() => {}) }, [])
  useEffect(reloadPresets, [reloadPresets])

  const fetcher = useCallback(
    (q: TableQuery) => api.results.runTable(study, run, selected!, q, group),
    [study, run, selected, group],
  )

  const distinctFetcher = useCallback(
    (column: string, activeFilters?: Record<string, ColFilter>) =>
      api.results.distinctValues(study, run, selected!, column, activeFilters, group),
    [study, run, selected, group],
  )

  const otuPopupFetcher = useCallback(
    async (row: Record<string, unknown>): Promise<RowPopupData | null> => {
      const seqName = String(row['SeqName'] ?? '')
      if (!seqName) return null
      try {
        const data = await api.results.otuMembers(study, run, seqName, group)
        return data.rows.length > 0 ? { columns: data.columns, rows: data.rows } : null
      } catch { return null }
    },
    [study, run, group],
  )

  const [otuCellLabels, setOtuCellLabels] = useState<Record<string, Record<string, string>>>({})
  const [mergedColumns, setMergedColumns] = useState<string[]>([])
  useEffect(() => {
    if (selected !== 'merged_otu') { setOtuCellLabels({}); setMergedColumns([]); return }
    api.results.otuCounts(study, run, group).then(({ counts }) => {
      const labels: Record<string, string> = {}
      for (const [otu, n] of Object.entries(counts)) {
        labels[otu] = `${otu} (${n})`
      }
      setOtuCellLabels({ SeqName: labels })
    }).catch(() => setOtuCellLabels({}))
    api.results.runTable(study, run, 'merged', { page: 1, perPage: 1 }, group)
      .then(d => setMergedColumns(d.columns))
      .catch(() => setMergedColumns([]))
  }, [study, run, selected, group])

  const importFilters = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const reader = new FileReader()
    reader.onload = () => {
      try {
        const text = reader.result as string
        const parsed = parseFilterYaml(text)
        setFilters(parsed)
        setFilterKey(k => k + 1)
      } catch (err) {
        toast.error('Failed to parse filter YAML: ' + (errorMessage(err)))
      }
    }
    reader.readAsText(file)
    e.target.value = ''
  }

  const applyPreset = async (preset: FilterPreset) => {
    if (!selected) return
    setLoadingPreset(true)
    try {
      const result = await api.presets.apply(study, run, selected, preset.file, group)
      const newFilters: Record<string, ColFilter> = {}
      for (const [col, f] of Object.entries(result.filters)) {
        const cf: ColFilter = {}
        if (f.include) cf.include = f.include
        if (f.min != null) cf.min = f.min
        if (f.max != null) cf.max = f.max
        newFilters[col] = cf
      }
      setFilters(newFilters)
      setFilterKey(k => k + 1)
    } catch (err) {
      toast.error('Failed to apply preset: ' + (errorMessage(err)))
    } finally {
      setLoadingPreset(false)
    }
  }

  const saveFilters = async () => {
    const name = prompt('Filter name (e.g. eukaryotes_only):')
    if (!name) return
    setSaving(true)
    try {
      await api.presets.save(name, filters, `Saved from table ${selected}`)
      reloadPresets()
    } catch (err) {
      toast.error('Failed to save filters: ' + (errorMessage(err)))
    } finally {
      setSaving(false)
    }
  }

  const saveTable = async () => {
    const name = prompt('Table name (saved to merged/ directory):')
    if (!name) return
    setSaving(true)
    try {
      const result = await api.results.saveTable(study, run, selected!, name,
        filters, sortBy ?? undefined, sortDir, group)
      onTablesChanged()
      toast.success(`Saved ${result.rows} rows to ${result.name}.csv`)
    } catch (err) {
      toast.error('Failed to save table: ' + (errorMessage(err)))
    } finally {
      setSaving(false)
    }
  }

  const deleteTable = async (id: string) => {
    if (!confirm(`Delete table "${id}"?`)) return
    try {
      await api.results.deleteTable(study, run, id, group)
      if (selected === id) setSelected(tables.find(t => t.id !== id)?.id ?? null)
      onTablesChanged()
    } catch (err) {
      toast.error('Failed to delete table: ' + (errorMessage(err)))
    }
  }

  const deletePreset = async (preset: FilterPreset) => {
    if (!confirm(`Delete filter preset "${preset.label}"?`)) return
    try {
      await api.presets.delete(preset.file)
      reloadPresets()
    } catch (err) {
      toast.error('Failed to delete preset: ' + (errorMessage(err)))
    }
  }

  const exportTable = async () => {
    try {
      await api.results.exportTable(study, run, selected!,
        filters, sortBy ?? undefined, sortDir, group)
    } catch (err) {
      toast.error('Failed to export table: ' + (errorMessage(err)))
    }
  }

  if (tables.length === 0) return <div className="empty-state">No tables generated yet.</div>

  return (
    <>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 8 }}>
        {tables.map(t => (
          <button
            key={t.id}
            className={`btn ${selected === t.id ? 'btn-primary' : ''}`}
            onClick={() => { setSelected(t.id); setFilters({}); setSortBy(null); setSortDir('asc'); setFilterKey(k => k + 1); setLiveStats(null) }}
          >
            {t.label} ({t.rows})
            {t.id !== 'merged' && t.id !== 'merged_otu' && (
              <span
                style={{ marginLeft: 6, opacity: 0.6, cursor: 'pointer' }}
                title={`Delete ${t.id}`}
                onClick={e => { e.stopPropagation(); deleteTable(t.id) }}
              >&times;</span>
            )}
          </button>
        ))}
      </div>

      {selected && (() => {
        const meta = tables.find(t => t.id === selected)
        if (!meta) return null
        const copy = (v: string | number) => () => navigator.clipboard.writeText(String(v))
        const N = ({ v, raw }: { v: string | number; raw?: string | number }) => (
          <strong onClick={copy(raw ?? v)} style={{ color: 'var(--color-fg)', cursor: 'pointer' }} title="Click to copy">
            {typeof v === 'number' ? v.toLocaleString() : v}
          </strong>
        )
        const fmt = (n: number) => n.toLocaleString()
        const s = liveStats
        const isFiltered = s != null && s.total !== s.total_unfiltered
        const hasReads   = s != null && s.total_reads_unfiltered > 0
        const pct        = hasReads && isFiltered ? Math.round(s.total_reads / s.total_reads_unfiltered * 100) : null
        const avg        = hasReads && meta.n_samples > 0
          ? Math.round((isFiltered ? s.total_reads : s!.total_reads_unfiltered) / meta.n_samples)
          : null

        const parts: React.ReactNode[] = []

        if (meta.n_samples > 0)
          parts.push(<span key="samples"><N v={meta.n_samples} /> {meta.n_samples === 1 ? 'sample' : 'samples'}</span>)

        if (s != null) {
          parts.push(
            isFiltered
              ? <span key="rows"><N v={s.total} /> / <N v={s.total_unfiltered} /> rows</span>
              : <span key="rows"><N v={s.total_unfiltered} /> rows</span>
          )
          if (hasReads) {
            parts.push(
              isFiltered
                ? <span key="reads"><N v={fmt(s.total_reads)} raw={s.total_reads} /> / <N v={fmt(s.total_reads_unfiltered)} raw={s.total_reads_unfiltered} /> reads{pct != null ? <> (<N v={`${pct}%`} raw={pct} />)</> : null}</span>
                : <span key="reads"><N v={fmt(s.total_reads_unfiltered)} raw={s.total_reads_unfiltered} /> reads</span>
            )
          }
          if (avg != null)
            parts.push(<span key="avg"><N v={fmt(avg)} raw={avg} /> avg reads/sample</span>)
        }

        return parts.length > 0 ? (
          <div style={{ marginBottom: 10, fontSize: '.82rem', color: 'var(--color-muted-fg)', display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'center' }}>
            {parts}
          </div>
        ) : null
      })()}

      {selected && (
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12, fontSize: '.82rem' }}>
          {presets.length > 0 && (
            <select
              style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)', fontSize: '.82rem', background: 'var(--color-bg)' }}
              value=""
              onChange={e => {
                const val = e.target.value
                if (val.startsWith('apply:')) {
                  const p = presets.find(p => p.file === val.slice(6))
                  if (p) applyPreset(p)
                } else if (val.startsWith('delete:')) {
                  const p = presets.find(p => p.file === val.slice(7))
                  if (p) deletePreset(p)
                }
              }}
              disabled={loadingPreset}
            >
              <option value="">{loadingPreset ? 'Applying...' : 'Presets...'}</option>
              <optgroup label="Apply">
                {presets.map(p => (
                  <option key={'a:' + p.file} value={'apply:' + p.file} title={p.description}>{p.label}</option>
                ))}
              </optgroup>
              <optgroup label="Delete">
                {presets.map(p => (
                  <option key={'d:' + p.file} value={'delete:' + p.file}>{p.label}</option>
                ))}
              </optgroup>
            </select>
          )}
          <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }}
            onClick={saveFilters} disabled={saving}>Save filters</button>
          <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }}
            onClick={() => fileInputRef.current?.click()}>Import filters</button>
          <input ref={fileInputRef} type="file" accept=".yml,.yaml" style={{ display: 'none' }}
            onChange={importFilters} />
          <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }}
            onClick={saveTable} disabled={saving}>Save table</button>
          <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }}
            onClick={exportTable}>Export table</button>
        </div>
      )}

      {selected && (
        <>
          <DataTable
            key={filterKey}
            storageKey={`tbl:${study}/${run}/${group ?? ''}/${selected}`}
            fetcher={fetcher}
            refreshKey={cacheKey}
            distinctFetcher={distinctFetcher}
            rowPopupFetcher={selected === 'merged_otu' ? otuPopupFetcher : undefined}
            popupColumns={selected === 'merged_otu' ? mergedColumns : undefined}
            cellLabels={selected === 'merged_otu' ? otuCellLabels : undefined}
            initialFilters={filters}
            onFiltersChange={setFilters}
            onSortChange={(sb, sd) => { setSortBy(sb); setSortDir(sd) }}
            onStatsChange={setLiveStats}
            showTaxonomyPresets
          />
          <AnalysisPanel
            study={study} run={run} group={group}
            table={selected} filters={filters}
          />
        </>
      )}
    </>
  )
}

function AnalysisPanel({ study, run, group, table, filters }: {
  study: string; run: string; group?: string; table: string
  filters: Record<string, ColFilter>
}) {
  const [analysisTables, setAnalysisTables] = useState<AnalysisOption[]>([])
  const [analysisKey, setAnalysisKey] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    discoverAnnotationOptions(study, run, group).then(options => {
      if (cancelled) return
      setAnalysisTables(options)
      const preferred = options.find(o => o.table === table) ?? options[0] ?? null
      setAnalysisKey(current => current && options.some(o => o.key === current) ? current : preferred?.key ?? null)
    })
    return () => { cancelled = true }
  }, [study, run, group, table])

  const selectedAnalysis = useMemo(
    () => analysisTables.find(option => option.key === analysisKey) ?? null,
    [analysisTables, analysisKey],
  )

  const analysis = useAnalysis({
    study, run, group,
    table: selectedAnalysis?.table ?? null,
    source: selectedAnalysis?.source,
    colFilters: filters,
  })

  const body = selectedAnalysis ? { table: selectedAnalysis.table, source: selectedAnalysis.source, colFilters: filters } : null

  const tableSelector = analysisTables.length > 1 ? (
    <select value={analysisKey ?? ''} onChange={e => setAnalysisKey(e.target.value)}
      style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)',
               fontSize: '.82rem', background: 'var(--color-bg)' }}>
      {analysisTables.map(option => <option key={option.key} value={option.key}>{option.label}</option>)}
    </select>
  ) : analysisTables.length === 1 ? (
    <code>{analysisTables[0].label}</code>
  ) : (
    <span style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>No annotated tables available</span>
  )

  return (
    <AnalysisControls {...analysis} body={body}>
      {tableSelector}
    </AnalysisControls>
  )
}

function PipelineStatsChart({ study, run, group }: { study: string; run: string; group?: string }) {
  const fetcher = useCallback(
    () => api.analysis.pipelineStats(study, run, group),
    [study, run, group]
  )
  const { data: figure } = useApi(fetcher)
  if (!figure) return null
  return (
    <div className="card" style={{ marginTop: 16 }}>
      <div className="card-title">Pipeline Stats</div>
      <PlotlyChart figure={figure} heightRatio={0.2} />
    </div>
  )
}

function parseFilterYaml(text: string): Record<string, ColFilter> {
  const result: Record<string, ColFilter> = {}
  const lines = text.split('\n')
  let currentCol: string | null = null
  let inInclude = false

  for (const line of lines) {
    const trimmed = line.trim()
    if (trimmed.startsWith('#') || trimmed === '' || trimmed === 'filters:' || trimmed === 'filters: {}') continue

    const colMatch = line.match(/^  (\S+):$/)
    if (colMatch) {
      currentCol = colMatch[1]
      result[currentCol] = {}
      inInclude = false
      continue
    }

    if (!currentCol) continue

    if (trimmed === 'include:') {
      inInclude = true
      result[currentCol].include = []
      continue
    }

    if (inInclude && trimmed.startsWith('- ')) {
      const val = trimmed.slice(2).replace(/^["']|["']$/g, '')
      result[currentCol].include = result[currentCol].include ?? []
      result[currentCol].include!.push(val)
      continue
    }

    const numMatch = trimmed.match(/^(min|max):\s*(.+)$/)
    if (numMatch) {
      inInclude = false
      const num = parseFloat(numMatch[2])
      if (!isNaN(num)) {
        if (numMatch[1] === 'min') result[currentCol].min = num
        else result[currentCol].max = num
      }
      continue
    }

    inInclude = false
  }

  return result
}
