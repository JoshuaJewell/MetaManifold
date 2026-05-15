// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useAnalysis } from '../hooks/useAnalysis'
import { DataTable } from './DataTable'
import { AnalysisControls } from './AnalysisControls'
import { useToast } from './Toast'
import { AddFuncdbModal, ContamStatsBar } from './AnnotationPanelControls'
import { BLAST_ASSIGNMENT_COLUMN, CONTAM_STYLE, findFinestRank, prefillFromRow, RANK_COL, SOURCES, type ContamStatus } from './annotationShared'
import type { AnnotationMeta, AnnotationSource, ColFilter, ContaminationStats, TableQuery } from '../api/types'

type UIStatus = AnnotationMeta['status'] | 'generating' | 'error'

function BlastAssignmentCell({
  value,
  onSave,
}: {
  value: string
  onSave: (nextValue: string) => Promise<void>
}) {
  const [draft, setDraft] = useState(value)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    setDraft(value)
  }, [value])

  const commit = useCallback(async () => {
    if (saving || draft === value) return
    setSaving(true)
    try {
      await onSave(draft)
    } finally {
      setSaving(false)
    }
  }, [draft, onSave, saving, value])

  return (
    <input
      value={draft}
      placeholder="Edit assignment"
      title="BLAST Assignment"
      onChange={event => setDraft(event.target.value)}
      onBlur={() => { void commit() }}
      onClick={event => event.stopPropagation()}
      onKeyDown={event => {
        if (event.key === 'Enter') {
          event.preventDefault()
          void commit()
        } else if (event.key === 'Escape') {
          setDraft(value)
        }
      }}
      style={{
        width: '100%',
        minWidth: 160,
        padding: '2px 6px',
        borderRadius: 4,
        border: '1px solid var(--color-border)',
        fontSize: '.75rem',
        background: 'var(--color-bg)',
        opacity: saving ? 0.7 : 1,
      }}
    />
  )
}

function AnnotationStatusBadge({ status }: { status: UIStatus }) {
  const statusStyles: Record<UIStatus, { bg: string; fg: string; label: string }> = {
    missing:    { bg: '#6b7280', fg: '#fff', label: 'Missing' },
    fresh:      { bg: '#10b981', fg: '#fff', label: 'Fresh' },
    stale:      { bg: '#f59e0b', fg: '#000', label: 'Stale' },
    generating: { bg: '#3b82f6', fg: '#fff', label: 'Generating...' },
    error:      { bg: '#ef4444', fg: '#fff', label: 'Error' },
  }

  const style = statusStyles[status]
  return (
    <span style={{
      display: 'inline-block', padding: '2px 8px', borderRadius: 4,
      fontSize: '.75rem', fontWeight: 600, background: style.bg, color: style.fg,
      marginLeft: 8, verticalAlign: 'middle',
    }}>
      {style.label}
    </span>
  )
}

export function AnnotationPanel({ study, run, group, subgroups }: { study: string; run: string; group?: string; subgroups?: string[] }) {
  const toast = useToast()
  const [source, setSource] = useState<AnnotationSource>('VSEARCH')
  const [listing, setListing] = useState<AnnotationMeta[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [uiStatus, setUiStatus] = useState<UIStatus>('missing')
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [contamOverrides, setContamOverrides] = useState<Record<string, ContamStatus>>({})
  const [addFuncdbPrefill, setAddFuncdbPrefill] = useState<Record<string, string> | null>(null)
  const [defaultModifiedBy, setDefaultModifiedBy] = useState('')
  const [configMaxRank, setConfigMaxRank] = useState<string>('species')
  const [contamStats, setContamStats] = useState<ContaminationStats | null>(null)
  const [blastAssignmentRefreshKey, setBlastAssignmentRefreshKey] = useState(0)
  const [filters, setFilters] = useState<Record<string, ColFilter>>({})
  const [selectedSubgroup, setSelectedSubgroup] = useState<string | null>(null)
  const selectedRef = useRef(selected)
  selectedRef.current = selected

  const selectedMeta = useMemo(
    () => listing.find(item => item.table === selected) ?? null,
    [listing, selected],
  )

  useEffect(() => {
    api.config.getDefault().then(cfg => {
      const value = cfg.your_name?.value
      if (typeof value === 'string') setDefaultModifiedBy(value)
    }).catch(() => {})
  }, [])

  useEffect(() => {
    if (!study || !run) return
    api.config.getRun(study, run, group ?? null).then(cfg => {
      const entry = cfg['annotation.max_rank'] as { value?: unknown } | undefined
      const v = typeof entry?.value === 'string' ? entry.value : 'species'
      setConfigMaxRank(v)
    }).catch(() => {})
  }, [study, run, group])

  const fetchListing = useCallback(async () => {
    try {
      setLoading(true)
      const items = await api.annotations.list(study, run, source, group)
      setListing(items)
      const cur = selectedRef.current
      const preferred = (cur ? items.find(item => item.table === cur) : null)
        ?? items.find(item => item.status === 'fresh' || item.status === 'stale')
        ?? items[0]

      setSelected(preferred?.table ?? null)
      setUiStatus(preferred?.status ?? 'missing')
      setErrorMsg(null)
    } catch (err) {
      toast.error('Failed to load annotation listing')
      setErrorMsg(errorMessage(err))
      setUiStatus('error')
    } finally {
      setLoading(false)
    }
  }, [study, run, source, group, toast])

  useEffect(() => { void fetchListing() }, [fetchListing])

  const fetchStats = useCallback(async () => {
    if (!selected || (uiStatus !== 'fresh' && uiStatus !== 'stale')) {
      setContamStats(null)
      return
    }
    try {
      setContamStats(await api.annotations.contaminationStats(study, run, source, selected, group))
    } catch {
      setContamStats(null)
    }
  }, [study, run, source, selected, group, uiStatus])

  useEffect(() => { void fetchStats() }, [fetchStats])

  const analysisEnabled = uiStatus === 'fresh' || uiStatus === 'stale'
  const analysis = useAnalysis({
    study, run, group, source,
    table: selected,
    colFilters: filters,
    prefix: selectedSubgroup || undefined,
    subgroups,
    enabled: analysisEnabled,
  })

  useEffect(() => {
    setContamOverrides({})
    setContamStats(null)
    analysis.resetFigures()
  }, [source, selected, analysis.resetFigures])

  const handleSelect = useCallback((table: string) => {
    setSelected(table)
    const meta = listing.find(item => item.table === table)
    if (meta) {
      setUiStatus(meta.status)
      setErrorMsg(null)
    }
  }, [listing])

  const handleGenerate = useCallback(async () => {
    if (!selected) return
    setUiStatus('generating')
    setErrorMsg(null)
    try {
      await api.annotations.generate(study, run, source, selected, group)
      await fetchListing()
    } catch (err) {
      setUiStatus('error')
      setErrorMsg(errorMessage(err))
      toast.error('Annotation generation failed')
    }
  }, [fetchListing, group, run, selected, source, study, toast])

  const maxRank = configMaxRank in RANK_COL ? configMaxRank : 'species'

  const handleContaminationChange = useCallback(async (
    row: Record<string, unknown>,
    newStatus: ContamStatus,
  ) => {
    if (!selected) return
    const rank = String(row.match_rank ?? '')
    if (!rank) return

    // For unmatched rows, find the finest rank with a non-empty value in the row,
    // starting from the configured max_rank. This handles tables that don't have
    // a Species column (e.g. protist tables whose finest rank is Genus).
    const effectiveRank = rank === 'unmatched'
      ? findFinestRank(row, source, maxRank) ?? maxRank
      : rank
    const taxonCol = RANK_COL[effectiveRank]?.[source]
    const taxon = taxonCol ? String(row[taxonCol] ?? '') : ''
    if (!taxon) return

    const overrideKey = `${rank}:${taxon.toLowerCase().trim()}`
    setContamOverrides(current => ({ ...current, [overrideKey]: newStatus }))

    try {
      const response = await api.annotations.updateContamination(
        study, run, source, selected, rank, taxon, newStatus, group,
      )
      if (response.rows_affected > 1) toast.success(`${response.rows_affected} rows updated`)
      void fetchStats()
    } catch (err) {
      setContamOverrides(current => {
        const next = { ...current }
        delete next[overrideKey]
        return next
      })
      toast.error(errorMessage(err, 'Update failed'))
    }
  }, [fetchStats, group, maxRank, run, selected, source, study, toast])


  const cellRenderer = useCallback((
    column: string,
    value: string,
    row: Record<string, unknown>,
  ): ReactNode | null => {
    if (column !== 'Contamination') return null

    const rank = String(row.match_rank ?? '')
    const effectiveRank = rank === 'unmatched'
      ? findFinestRank(row, source, maxRank) ?? maxRank
      : rank
    const taxonCol = RANK_COL[effectiveRank]?.[source]
    const taxon = taxonCol ? String(row[taxonCol] ?? '').toLowerCase().trim() : ''
    const overrideKey = `${rank}:${taxon}`
    const resolved = (contamOverrides[overrideKey] ?? (value || 'unassigned')) as ContamStatus

    return (
      <select
        value={resolved}
        onChange={event => {
          event.stopPropagation()
          void handleContaminationChange(row, event.target.value as ContamStatus)
        }}
        onClick={event => event.stopPropagation()}
        style={{
          border: 'none',
          background: 'transparent',
          cursor: 'pointer',
          fontSize: 'inherit',
          padding: 0,
          ...CONTAM_STYLE[resolved],
        }}
      >
        <option value="unassigned">unassigned</option>
        <option value="yes">yes</option>
        <option value="no">no</option>
      </select>
    )
  }, [contamOverrides, handleContaminationChange, maxRank, source])

  const extraRowActions = useCallback((row: Record<string, unknown>) => (
    <button
      className="btn"
      style={{ padding: '1px 6px', fontSize: '.75rem', marginLeft: 4 }}
      title="Add this taxon to FuncDB"
      onClick={event => {
        event.stopPropagation()
        setAddFuncdbPrefill(prefillFromRow(row, source))
      }}
    >
      +
    </button>
  ), [source])

  const fetcher = useCallback(
    (query: TableQuery) => api.annotations.query(study, run, source, selected!, query, group),
    [group, run, selected, source, study],
  )

  const distinctFetcher = useCallback(
    (column: string, activeFilters?: Record<string, ColFilter>) =>
      api.annotations.distinct(study, run, source, selected!, column, activeFilters, group),
    [group, run, selected, source, study],
  )


  const handleBlastAssignmentSave = useCallback(async (
    row: Record<string, unknown>,
    nextValue: string,
  ) => {
    if (!selected) return
    const sequence = String(row.sequence ?? '').trim()
    if (!sequence) {
      toast.error('This row has no sequence value to identify it')
      return
    }

    try {
      await api.annotations.updateBlastAssignment(
        study, run, source, selected, sequence, nextValue, group,
      )
      setBlastAssignmentRefreshKey(current => current + 1)
    } catch (err) {
      toast.error(errorMessage(err, 'Failed to update BLAST Assignment'))
      throw err
    }
  }, [group, run, selected, source, study, toast])

  const mergedCellRenderer = useCallback((
    column: string,
    value: string,
    row: Record<string, unknown>,
  ): ReactNode | null => {
    if (column === BLAST_ASSIGNMENT_COLUMN) {
      return (
        <BlastAssignmentCell
          value={value}
          onSave={nextValue => handleBlastAssignmentSave(row, nextValue)}
        />
      )
    }
    return cellRenderer(column, value, row)
  }, [cellRenderer, handleBlastAssignmentSave])

  const showTable = uiStatus === 'fresh' || uiStatus === 'stale'
    || (uiStatus === 'generating' && selectedMeta?.status !== 'missing')

  return (
    <div className="card">
      <div className="tabs" style={{ marginBottom: 12 }}>
        {SOURCES.map(item => (
          <button
            key={item}
            className={`tab ${source === item ? 'active' : ''}`}
            onClick={() => setSource(item)}
          >
            {item}
          </button>
        ))}
      </div>

      {loading && <p style={{ color: 'var(--color-muted-fg)' }}>Loading...</p>}

      {!loading && listing.length === 0 && (
        <p style={{ color: 'var(--color-muted-fg)' }}>No annotation tables available for {source}.</p>
      )}

      {!loading && listing.length > 0 && (
        <>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 12, flexWrap: 'wrap' }}>
            <label style={{ fontWeight: 600, fontSize: '.85rem' }}>Table:</label>
            <select
              value={selected ?? ''}
              onChange={event => handleSelect(event.target.value)}
              disabled={uiStatus === 'generating'}
              style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)' }}
            >
              {listing.map(item => (
                <option key={item.table} value={item.table}>
                  {item.table} {item.rows != null ? `(${item.rows} rows)` : ''}
                </option>
              ))}
            </select>

            {selected && <AnnotationStatusBadge status={uiStatus} />}

            {selected && uiStatus !== 'generating' && (
              <>
                <button
                  className={`btn ${uiStatus === 'stale' || uiStatus === 'missing' || uiStatus === 'error' ? 'btn-primary' : ''}`}
                  onClick={handleGenerate}
                >
                  {uiStatus === 'missing' ? 'Generate' : uiStatus === 'error' ? 'Retry' : 'Regenerate'}
                </button>
                {showTable && (
                  <>
                    <button className="btn" onClick={() => api.annotations.exportCsv(study, run, source, selected, group)}
                      title="Download annotation table as CSV">
                      Export CSV
                    </button>
                  </>
                )}
              </>
            )}

            {uiStatus === 'generating' && (
              <span style={{ fontSize: '.85rem', color: 'var(--color-muted-fg)' }}>Generating...</span>
            )}
          </div>

          {uiStatus === 'stale' && (
            <div style={{
              padding: '8px 12px', marginBottom: 12, borderRadius: 4,
              background: '#fef3c7', color: '#92400e', fontSize: '.85rem',
              border: '1px solid #fcd34d',
            }}>
              Source data has changed - regenerate to update
            </div>
          )}

          {uiStatus === 'error' && errorMsg && (
            <div style={{
              padding: '8px 12px', marginBottom: 12, borderRadius: 4,
              background: '#fee2e2', color: '#991b1b', fontSize: '.85rem',
              border: '1px solid #fca5a5',
            }}>
              {errorMsg}
            </div>
          )}

          {uiStatus === 'generating' && (
            <div style={{
              padding: '8px 12px', marginBottom: 12, borderRadius: 4,
              background: '#dbeafe', color: '#1e40af', fontSize: '.85rem',
              border: '1px solid #93c5fd',
            }}>
              Generating...
            </div>
          )}

          {selected && showTable && contamStats && (
            <ContamStatsBar stats={contamStats} />
          )}

          {selected && showTable && (
            <>
              <DataTable
                key={`${source}-${selected}`}
                storageKey={`ann:${study}/${run}/${group ?? ''}/${source}/${selected}`}
                refreshKey={blastAssignmentRefreshKey}
                fetcher={fetcher}
                distinctFetcher={distinctFetcher}
                cellRenderer={mergedCellRenderer}
                extraRowActions={extraRowActions}
                onFiltersChange={setFilters}
              />

              {analysis.ranks.length > 0 && (
                <AnalysisControls {...analysis} body={selected}>
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
                </AnalysisControls>
              )}
            </>
          )}
        </>
      )}


      {addFuncdbPrefill !== null && (
        <AddFuncdbModal
          prefill={addFuncdbPrefill}
          defaultModifiedBy={defaultModifiedBy}
          onClose={() => setAddFuncdbPrefill(null)}
          onSuccess={handleGenerate}
        />
      )}
    </div>
  )
}
