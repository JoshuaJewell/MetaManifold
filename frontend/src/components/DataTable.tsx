// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useState, useCallback, useEffect, useRef } from 'react'
import { useApi } from '../hooks/useApi'
import type { TablePage, TableQuery, ColFilter, DistinctInfo } from '../api/types'
import styles from './DataTable.module.css'

const blastUrl = (seq: string) =>
  `https://blast.ncbi.nlm.nih.gov/Blast.cgi?PROGRAM=blastn&DATABASE=nt&CMD=Put&ENTREZ_QUERY=NOT+uncultured+organism%5Borganism%5D+NOT+environmental+sample%5Borganism%5D&QUERY=${encodeURIComponent(seq)}`

export interface RowPopupData {
  columns: string[]
  rows: Record<string, unknown>[]
}

export interface TableStats {
  total:                  number
  total_unfiltered:       number
  total_reads:            number
  total_reads_unfiltered: number
}

interface Props {
  fetcher: (q: TableQuery) => Promise<TablePage>
  refreshKey?: string | number | null
  /** Stable key for persisting column visibility, sort, and filters to sessionStorage. */
  storageKey?: string
  distinctFetcher?: (column: string, activeFilters?: Record<string, ColFilter>) => Promise<DistinctInfo>
  rowPopupFetcher?: (row: Record<string, unknown>) => Promise<RowPopupData | null>
  /** Extra columns available only in the popup (e.g. merged table columns not in merged_otu). */
  popupColumns?: string[]
  /** Map from cell value to display label, keyed by column name. E.g. { SeqName: { otu1: 'otu1 (3)' } }. */
  cellLabels?: Record<string, Record<string, string>>
  /** Override cell rendering for specific columns. Return null to fall back to default. */
  cellRenderer?: (column: string, value: string, row: Record<string, unknown>) => React.ReactNode | null
  /** Extra actions rendered in the action cell (same cell as BLAST, or its own cell if no sequence col). */
  extraRowActions?: (row: Record<string, unknown>) => React.ReactNode
  /** Show VSEARCH / DADA2 taxonomy column preset buttons (Tables tab). The All button is always shown when _dada2 cols are present. */
  showTaxonomyPresets?: boolean
  perPage?: number
  initialFilters?: Record<string, ColFilter>
  onFiltersChange?: (filters: Record<string, ColFilter>) => void
  onSortChange?: (sortBy: string | null, sortDir: 'asc' | 'desc') => void
  onStatsChange?: (stats: TableStats | null) => void
}

interface PersistedTableState {
  hiddenCols?: string[]
  stickyCols?: string[]
  sortBy?: string | null
  sortDir?: SortDir
  colFilters?: Record<string, ColFilter>
  activePreset?: 'vsearch' | 'dada2' | null
}

function loadPersistedState(key: string): PersistedTableState | null {
  try {
    const raw = sessionStorage.getItem(`dt:${key}`)
    return raw ? JSON.parse(raw) : null
  } catch { return null }
}

function savePersistedState(key: string, state: PersistedTableState) {
  try {
    sessionStorage.setItem(`dt:${key}`, JSON.stringify(state))
  } catch { /* quota exceeded - ignore */ }
}

type SortDir = 'asc' | 'desc'

export function DataTable({ fetcher, refreshKey, storageKey, distinctFetcher, rowPopupFetcher, popupColumns, cellLabels, cellRenderer, extraRowActions, showTaxonomyPresets = false, perPage = 100, initialFilters, onFiltersChange, onSortChange, onStatsChange }: Props) {
  const [persisted] = useState(() => storageKey ? loadPersistedState(storageKey) : null)
  const [page, setPage]             = useState(1)
  const [filter, setFilter]         = useState('')
  const [sortBy, setSortBy]         = useState<string | null>(persisted?.sortBy ?? null)
  const [sortDir, setSortDir]       = useState<SortDir>(persisted?.sortDir ?? 'asc')
  const [colFilters, _setColFilters] = useState<Record<string, ColFilter>>(
    persisted?.colFilters ?? initialFilters ?? {},
  )
  const [openDropdown, setOpenDropdown] = useState<string | null>(null)
  const [hiddenCols, setHiddenCols] = useState<Set<string>>(new Set(persisted?.hiddenCols))
  const [stickyCols, setStickyCols] = useState<Set<string>>(new Set(persisted?.stickyCols))
  const [showColPicker, setShowColPicker] = useState(false)
  const [activePreset, setActivePreset] = useState<'vsearch' | 'dada2' | null>(persisted?.activePreset ?? null)
  const colPickerRef = useRef<HTMLDivElement>(null)

  const [popupData, setPopupData]       = useState<RowPopupData | null>(null)
  const [popupLoading, setPopupLoading] = useState(false)
  const [popupPos, setPopupPos]         = useState<{ x: number; y: number }>({ x: 0, y: 0 })
  const [popupRowIdx, setPopupRowIdx]   = useState<number | null>(null)
  const popupTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const popupRef   = useRef<HTMLDivElement>(null)

  const startPopup = useCallback((row: Record<string, unknown>, rowIdx: number, e: React.MouseEvent) => {
    if (!rowPopupFetcher) return
    if (popupTimer.current) clearTimeout(popupTimer.current)
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
    popupTimer.current = setTimeout(() => {
      setPopupPos({ x: rect.left, y: Math.min(rect.bottom + 4, window.innerHeight - 340) })
      setPopupRowIdx(rowIdx)
      setPopupLoading(true)
      setPopupData(null)
      rowPopupFetcher(row).then(data => {
        setPopupData(data)
        setPopupLoading(false)
      }).catch(() => { setPopupData(null); setPopupLoading(false) })
    }, 300)
  }, [rowPopupFetcher])

  const cancelTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const cancelPopup = useCallback(() => {
    if (popupTimer.current) { clearTimeout(popupTimer.current); popupTimer.current = null }
    if (cancelTimer.current) clearTimeout(cancelTimer.current)
    cancelTimer.current = setTimeout(() => {
      setPopupData(null)
      setPopupLoading(false)
      setPopupRowIdx(null)
    }, 150)
  }, [])

  const keepPopup = useCallback(() => {
    if (cancelTimer.current) { clearTimeout(cancelTimer.current); cancelTimer.current = null }
  }, [])

  const setColFilters = useCallback((updater: Record<string, ColFilter> | ((prev: Record<string, ColFilter>) => Record<string, ColFilter>)) => {
    _setColFilters(prev => typeof updater === 'function' ? updater(prev) : updater)
  }, [])

  useEffect(() => {
    onFiltersChange?.(colFilters)
  }, [colFilters]) // eslint-disable-line react-hooks/exhaustive-deps

  // Notify parent of restored sort state on mount.
  useEffect(() => {
    if (persisted?.sortBy !== undefined) onSortChange?.(sortBy, sortDir)
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (initialFilters && !persisted?.colFilters) {
      _setColFilters(initialFilters)
      onFiltersChange?.(initialFilters)
      setPage(1)
    }
  }, [initialFilters]) // eslint-disable-line react-hooks/exhaustive-deps

  // Persist table UI state to sessionStorage on change.
  useEffect(() => {
    if (!storageKey) return
    savePersistedState(storageKey, {
      hiddenCols: [...hiddenCols],
      stickyCols: [...stickyCols],
      sortBy,
      sortDir,
      colFilters,
      activePreset,
    })
  }, [storageKey, hiddenCols, stickyCols, sortBy, sortDir, colFilters, activePreset])

  const bound = useCallback(() => {
    const q: TableQuery = { page, perPage }
    if (filter) q.filter = filter
    if (sortBy) { q.sortBy = sortBy; q.sortDir = sortDir }
    const active: Record<string, ColFilter> = {}
    for (const [col, f] of Object.entries(colFilters)) {
      if (f.include != null || f.min != null || f.max != null) active[col] = f
    }
    if (Object.keys(active).length > 0) q.colFilters = active
    return fetcher(q)
  }, [fetcher, page, perPage, filter, sortBy, sortDir, colFilters])

  const { data, loading, error, refetch } = useApi(bound)

  const prevRefreshKey = useRef(refreshKey)
  useEffect(() => {
    if (refreshKey == null || refreshKey === prevRefreshKey.current) return
    prevRefreshKey.current = refreshKey
    refetch()
  }, [refreshKey, refetch])

  useEffect(() => {
    if (!data) { onStatsChange?.(null); return }
    onStatsChange?.({ total: data.total, total_unfiltered: data.total_unfiltered, total_reads: data.total_reads, total_reads_unfiltered: data.total_reads_unfiltered })
  }, [data]) // eslint-disable-line react-hooks/exhaustive-deps

  const rows  = data && Array.isArray(data.rows) ? data.rows : []
  const allCols = data && Array.isArray(data.columns) ? data.columns
              : (rows.length > 0 && rows[0] ? Object.keys(rows[0]) : [])
  const sampleCountColSet = new Set(data?.sample_count_columns ?? [])
  const allCountsHidden = sampleCountColSet.size > 0 && [...sampleCountColSet].every(c => hiddenCols.has(c))
  const cols = allCols.filter(c => !hiddenCols.has(c))
  const hasSequenceCol = allCols.includes('sequence')
  const pages = data ? Math.ceil(data.total / perPage) : 0

  const tableColSet = new Set(allCols)
  const extraPopupCols = (popupColumns ?? []).filter(c => !tableColSet.has(c))
  const pickerCols = [...allCols, ...extraPopupCols]
  const popupOnlySet = new Set(extraPopupCols)

  useEffect(() => {
    if (!showColPicker) return
    const handler = (e: MouseEvent) => {
      if (colPickerRef.current && !colPickerRef.current.contains(e.target as Node)) setShowColPicker(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [showColPicker])

  const handleSort = (col: string) => {
    let newSortBy: string | null
    let newSortDir: SortDir
    if (sortBy === col) {
      if (sortDir === 'asc') { newSortBy = col; newSortDir = 'desc' }
      else { newSortBy = null; newSortDir = 'asc' }
    } else {
      newSortBy = col; newSortDir = 'asc'
    }
    setSortBy(newSortBy)
    setSortDir(newSortDir)
    onSortChange?.(newSortBy, newSortDir)
    setPage(1)
  }

  const updateColFilter = (col: string, patch: ColFilter | undefined) => {
    setColFilters(prev => {
      const next = { ...prev }
      if (!patch) delete next[col]
      else next[col] = patch
      return next
    })
    setPage(1)
  }

  const clearAllFilters = () => { setColFilters({}); setFilter(''); setPage(1) }

  const sortIndicator = (col: string) => {
    if (sortBy !== col) return <span className={styles.sortIcon}> +</span>
    return <span className={styles.sortIconActive}>{sortDir === 'asc' ? ' ^' : ' v'}</span>
  }

  const hasAnyFilter = !!filter || Object.keys(colFilters).length > 0
  const colIsFiltered = (col: string) => {
    const f = colFilters[col]
    return f && (f.include != null || f.min != null || f.max != null)
  }

  const toggleColVisibility = (col: string) => {
    setHiddenCols(prev => {
      const next = new Set(prev)
      if (next.has(col)) next.delete(col); else next.add(col)
      return next
    })
  }

  const toggleSticky = (col: string) => {
    setStickyCols(prev => {
      const next = new Set(prev)
      if (next.has(col)) next.delete(col); else next.add(col)
      return next
    })
  }


  const applyColumnPreset = (preset: 'vsearch' | 'dada2' | 'all') => {
    if (preset === 'all') {
      setHiddenCols(new Set())
      setColFilters({})
      setActivePreset(null)
      setPage(1)
      return
    }
    const vsearchOnlyCols = ['Pident', 'Accession', 'rRNA', 'Organellum', 'specimen']
    const vsearchTaxCols = pickerCols.filter(c => pickerCols.includes(c + '_dada2'))
    const dada2Cols = pickerCols.filter(c => c.endsWith('_dada2') || c.endsWith('_boot'))
    if (preset === 'vsearch') {
      setHiddenCols(new Set(dada2Cols))
      const filters: Record<string, ColFilter> = {}
      if (pickerCols.includes('Pident')) filters['Pident'] = { min: 0 }
      setColFilters(filters)
    } else {
      setHiddenCols(new Set([...vsearchOnlyCols.filter(c => pickerCols.includes(c)), ...vsearchTaxCols]))
      const filters: Record<string, ColFilter> = {}
      const bootCol = pickerCols.find(c => c.endsWith('_boot'))
      if (bootCol) filters[bootCol] = { min: 0 }
      setColFilters(filters)
    }
    setActivePreset(preset)
    setPage(1)
  }

  const stickyOffsets = new Map<string, number>()
  {
    let offset = 0
    for (const c of cols) {
      if (stickyCols.has(c)) {
        stickyOffsets.set(c, offset)
        offset += 140
      }
    }
  }

  return (
    <div className={styles.wrapper}>
      <div className={styles.toolbar}>
        <input
          className={styles.search}
          placeholder="Global filter..."
          value={filter}
          onChange={e => { setFilter(e.target.value); setPage(1) }}
        />
        {hasAnyFilter && (
          <button className="btn" style={{ fontSize: '.78rem', padding: '3px 8px' }}
            onClick={clearAllFilters}>Clear all filters</button>
        )}
        {pickerCols.length > 0 && (
          <div style={{ position: 'relative' }}>
            <button className="btn" style={{ fontSize: '.78rem', padding: '3px 8px' }}
              onClick={() => setShowColPicker(v => !v)}>
              Columns{hiddenCols.size > 0 ? ` (${pickerCols.length - hiddenCols.size}/${pickerCols.length})` : ''}
            </button>
            {showColPicker && (
              <div ref={colPickerRef} className={styles.dropdown}
                style={{ right: 0, left: 'auto', maxHeight: 320, overflowY: 'auto' }}>
                <div className={styles.dropdownActions}>
                  <button onClick={() => setHiddenCols(new Set())}>Show all</button>
                  <button onClick={() => setHiddenCols(new Set(pickerCols))}>Hide all</button>
                </div>
                <div className={styles.dropdownList}>
                  {pickerCols.map(c => (
                    <label key={c} className={styles.dropdownItem}>
                      <input type="checkbox" checked={!hiddenCols.has(c)}
                        onChange={() => toggleColVisibility(c)} />
                      <span>{c}{popupOnlySet.has(c) ? <span className={styles.popupOnlyTag}> (ASV)</span> : ''}</span>
                    </label>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
        {pickerCols.some(c => c.endsWith('_dada2')) && (
          <>
            {showTaxonomyPresets && (
              <>
                <button className={`btn${activePreset === 'vsearch' ? ' btn-primary' : ''}`} style={{ fontSize: '.78rem', padding: '3px 8px' }}
                  onClick={() => applyColumnPreset('vsearch')}>VSEARCH</button>
                <button className={`btn${activePreset === 'dada2' ? ' btn-primary' : ''}`} style={{ fontSize: '.78rem', padding: '3px 8px' }}
                  onClick={() => applyColumnPreset('dada2')}>DADA2</button>
              </>
            )}
            <button className={`btn${activePreset === null ? ' btn-primary' : ''}`} style={{ fontSize: '.78rem', padding: '3px 8px' }}
              onClick={() => applyColumnPreset('all')}>All</button>
          </>
        )}
        {sampleCountColSet.size > 0 && (
            <button
              className={`btn${allCountsHidden ? ' btn-primary' : ''}`}
              style={{ fontSize: '.78rem', padding: '3px 8px' }}
              onClick={() => setHiddenCols(prev => {
                const next = new Set(prev)
                if (allCountsHidden) sampleCountColSet.forEach(c => next.delete(c))
                else sampleCountColSet.forEach(c => next.add(c))
                return next
              })}
              title={allCountsHidden ? 'Show sample counts' : 'Hide sample counts'}
            >
              {allCountsHidden ? 'Show counts' : 'Hide counts'}
            </button>
        )}
      </div>

      {error && <p className={styles.error}>{error}</p>}
      {loading && cols.length === 0 && <p className={styles.msg}>Loading...</p>}
      {!loading && !error && cols.length === 0 && <p className={styles.msg}>No data.</p>}

      {cols.length > 0 && (
        <>
          <div className={styles.scroll}>
            <table className={styles.table}>
              <thead>
                <tr>
                  {cols.map(c => {
                    const isSticky = stickyCols.has(c)
                    const stickyStyle: React.CSSProperties | undefined = isSticky ? {
                      position: 'sticky',
                      left: stickyOffsets.get(c) ?? 0,
                      zIndex: 11,
                      background: 'var(--color-surface)',
                    } : undefined
                    return (
                      <th key={c} className={styles.sortable}
                        onClick={() => handleSort(c)}
                        style={stickyStyle}>
                        <span className={styles.headerLabel}>
                          {c}{sortIndicator(c)}
                        </span>
                        {distinctFetcher && (
                          <button
                            className={`${styles.dropdownBtn} ${colIsFiltered(c) ? styles.dropdownBtnActive : ''}`}
                            onClick={e => { e.stopPropagation(); setOpenDropdown(openDropdown === c ? null : c) }}
                            title="Filter values"
                          >v</button>
                        )}
                        {openDropdown === c && distinctFetcher && (
                          <ColumnDropdown
                            column={c}
                            distinctFetcher={distinctFetcher}
                            activeFilters={colFilters}
                            current={colFilters[c]}
                            isSticky={isSticky}
                            onToggleSticky={() => toggleSticky(c)}
                            onApply={f => { updateColFilter(c, f); setOpenDropdown(null) }}
                            onClose={() => setOpenDropdown(null)}
                          />
                        )}
                      </th>
                    )
                  })}
                  {(hasSequenceCol || extraRowActions) && <th style={{ width: hasSequenceCol && extraRowActions ? 90 : 60 }}></th>}
                </tr>
              </thead>
              <tbody>
                {loading && (
                  <tr><td colSpan={cols.length + (hasSequenceCol || extraRowActions ? 1 : 0)} className={styles.msg} style={{ textAlign: 'center' }}>Loading...</td></tr>
                )}
                {!loading && rows.length === 0 && (
                  <tr><td colSpan={cols.length + (hasSequenceCol || extraRowActions ? 1 : 0)} className={styles.msg} style={{ textAlign: 'center' }}>
                    {hasAnyFilter ? 'No matching rows.' : 'No data.'}
                  </td></tr>
                )}
                {!loading && rows.map((row, i) => (
                  <tr key={i}
                    onMouseEnter={rowPopupFetcher ? e => { keepPopup(); startPopup(row, i, e) } : undefined}
                    onMouseLeave={rowPopupFetcher ? cancelPopup : undefined}
                    className={popupRowIdx === i ? styles.popupActiveRow : undefined}
                  >
                    {cols.map(c => {
                      const isSticky = stickyCols.has(c)
                      const stickyStyle: React.CSSProperties | undefined = isSticky ? {
                        position: 'sticky',
                        left: stickyOffsets.get(c) ?? 0,
                        zIndex: 1,
                        background: 'var(--color-bg)',
                      } : undefined
                      const text = String(row[c] ?? '')
                      const custom = cellRenderer?.(c, text, row)
                      if (custom !== null && custom !== undefined) {
                        return <td key={c} style={stickyStyle}>{custom}</td>
                      }
                      const display = cellLabels?.[c]?.[text] ?? text
                      return (
                        <td key={c} style={stickyStyle}
                          onClick={e => {
                            navigator.clipboard.writeText(text)
                            const el = e.currentTarget
                            el.classList.remove(styles.copied)
                            void el.offsetWidth
                            el.classList.add(styles.copied)
                          }}
                          title="Click to copy"
                        >{display}</td>
                      )
                    })}
                    {(hasSequenceCol || extraRowActions) && (
                      <td className={styles.blastCell}>
                        {hasSequenceCol && (
                          <a
                            href={blastUrl(String(row['sequence'] ?? ''))}
                            target="_blank"
                            rel="noopener noreferrer"
                            className={styles.blastLink}
                            title="Search this sequence on NCBI BLAST"
                          >BLAST</a>
                        )}
                        {extraRowActions?.(row)}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {popupRowIdx !== null && (popupLoading || (popupData && popupData.rows.length > 0)) && (
            <div
              ref={popupRef}
              className={styles.popup}
              style={{ left: popupPos.x, top: popupPos.y }}
              onMouseEnter={keepPopup}
              onMouseLeave={cancelPopup}
            >
              {popupLoading && <div className={styles.popupTitle}>Loading...</div>}
              {!popupLoading && popupData && popupData.rows.length > 0 && (() => {
                const popupCols = popupData.columns.filter(c => !hiddenCols.has(c))
                const popupHasSeq = popupCols.includes('sequence')
                return (
                  <>
                    <div className={styles.popupTitle}>
                      ASV members ({popupData.rows.length})
                    </div>
                    <div className={styles.popupScroll}>
                      <table className={styles.popupTable}>
                        <thead>
                          <tr>
                            {popupCols.map(c => (
                              <th key={c}>{c}</th>
                            ))}
                            {popupHasSeq && <th style={{ width: 50 }}></th>}
                          </tr>
                        </thead>
                        <tbody>
                          {popupData.rows.map((r, i) => (
                            <tr key={i}>
                              {popupCols.map(c => {
                                const text = String(r[c] ?? '')
                                return (
                                  <td key={c}
                                    onClick={e => {
                                      navigator.clipboard.writeText(text)
                                      const el = e.currentTarget
                                      el.classList.remove(styles.copied)
                                      void el.offsetWidth
                                      el.classList.add(styles.copied)
                                    }}
                                    title="Click to copy"
                                  >{text}</td>
                                )
                              })}
                              {popupHasSeq && (
                                <td className={styles.blastCell}>
                                  <a
                                    href={blastUrl(String(r['sequence'] ?? ''))}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className={styles.blastLink}
                                    title="Search this sequence on NCBI BLAST"
                                  >BLAST</a>
                                </td>
                              )}
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </>
                )
              })()}
            </div>
          )}
          {pages > 1 && (
            <div className={styles.pager}>
              <button disabled={page <= 1} onClick={() => setPage(p => p - 1)}>{'< Prev'}</button>
              <span>Page {page} / {pages}</span>
              <button disabled={page >= pages} onClick={() => setPage(p => p + 1)}>{'Next >'}</button>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function ColumnDropdown({ column, distinctFetcher, activeFilters, current, isSticky, onToggleSticky, onApply, onClose }: {
  column:          string
  distinctFetcher: (col: string, activeFilters?: Record<string, ColFilter>) => Promise<DistinctInfo>
  activeFilters:   Record<string, ColFilter>
  current?:        ColFilter
  isSticky:        boolean
  onToggleSticky:  () => void
  onApply:         (f: ColFilter | undefined) => void
  onClose:         () => void
}) {
  const [info, setInfo]         = useState<DistinctInfo | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    let cancelled = false
    // Pass all filters except this column's so the dropdown shows contextual values.
    const otherFilters: Record<string, ColFilter> = {}
    for (const [col, f] of Object.entries(activeFilters)) {
      if (col !== column) otherFilters[col] = f
    }
    const hasOther = Object.keys(otherFilters).length > 0
    distinctFetcher(column, hasOther ? otherFilters : undefined)
      .then(d => { if (!cancelled) setInfo(d) })
      .catch(e => { if (!cancelled) setLoadError(e.message ?? 'Failed to load') })
    return () => { cancelled = true }
  }, [column, distinctFetcher, activeFilters])

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose()
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [onClose])

  return (
    <div ref={ref} className={styles.dropdown} onClick={e => e.stopPropagation()}>
      <label className={styles.dropdownItem} style={{ borderBottom: '1px solid var(--color-border)', paddingTop: 6, paddingBottom: 6 }}>
        <input type="checkbox" checked={isSticky} onChange={onToggleSticky} />
        <span style={{ fontWeight: 600, fontSize: '.78rem' }}>Sticky column</span>
      </label>
      {loadError && <div className={styles.dropdownError}>{loadError}</div>}
      {!info && !loadError && <div className={styles.dropdownLoading}>Loading...</div>}
      {info?.type === 'text' && (
        <TextFilter
          values={info.values}
          current={current?.include}
          onApply={vals => onApply(vals ? { include: vals } : undefined)}
        />
      )}
      {info?.type === 'numeric' && (
        <NumericFilter
          dataMin={info.min}
          dataMax={info.max}
          sum={info.sum}
          mean={info.mean}
          median={info.median}
          q1={info.q1}
          q3={info.q3}
          currentMin={current?.min}
          currentMax={current?.max}
          onApply={(min, max) => {
            if (min == null && max == null) onApply(undefined)
            else onApply({ min: min ?? undefined, max: max ?? undefined })
          }}
        />
      )}
    </div>
  )
}

function TextFilter({ values, current, onApply }: {
  values:   string[]
  current?: string[]
  onApply:  (vals: string[] | undefined) => void
}) {
  const [search, setSearch]   = useState('')
  const [checked, setChecked] = useState<Set<string>>(() => new Set(current ?? values))

  const visible = search
    ? values.filter(v => v.toLowerCase().includes(search.toLowerCase()))
    : values

  const allTicked = checked.size === values.length

  const toggle = (val: string) => {
    setChecked(prev => {
      const next = new Set(prev)
      if (next.has(val)) next.delete(val); else next.add(val)
      return next
    })
  }

  return (
    <>
      <input
        className={styles.dropdownSearch}
        placeholder="Search..."
        value={search}
        onChange={e => setSearch(e.target.value)}
        autoFocus
      />
      <div className={styles.dropdownActions}>
        <button onClick={() => setChecked(new Set(values))}>All</button>
        <button onClick={() => setChecked(new Set())}>None</button>
        <span className={styles.dropdownCount}>{checked.size}/{values.length}</span>
      </div>
      <div className={styles.dropdownList}>
        {visible.map(v => (
          <label key={v} className={styles.dropdownItem}>
            <input type="checkbox" checked={checked.has(v)} onChange={() => toggle(v)} />
            <span>{v || '(empty)'}</span>
          </label>
        ))}
        {visible.length === 0 && <div className={styles.dropdownEmpty}>No matching values</div>}
      </div>
      <div className={styles.dropdownFooter}>
        <button className="btn btn-primary" style={{ fontSize: '.78rem', padding: '3px 10px' }}
          onClick={() => onApply(allTicked ? undefined : [...checked])}>Apply</button>
        <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }}
          onClick={() => onApply(undefined)}>Clear</button>
      </div>
    </>
  )
}

function NumericFilter({ dataMin, dataMax, sum, mean, median, q1, q3, currentMin, currentMax, onApply }: {
  dataMin:     number
  dataMax:     number
  sum?:        number
  mean?:       number
  median?:     number
  q1?:         number
  q3?:         number
  currentMin?: number
  currentMax?: number
  onApply:     (min: number | null, max: number | null) => void
}) {
  const [minVal, setMinVal] = useState(currentMin != null ? String(currentMin) : '')
  const [maxVal, setMaxVal] = useState(currentMax != null ? String(currentMax) : '')

  const fmt = (v: number) => Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumFractionDigits: 2 })

  const apply = () => {
    const mn = minVal !== '' ? Number(minVal) : null
    const mx = maxVal !== '' ? Number(maxVal) : null
    onApply(
      mn != null && !isNaN(mn) ? mn : null,
      mx != null && !isNaN(mx) ? mx : null,
    )
  }

  return (
    <>
      {(sum != null || mean != null || median != null || q1 != null) && (
        <div className={styles.numericInfo} style={{ fontSize: '.75rem', color: 'var(--color-muted-fg)' }}>
          {sum != null && <div>Sum: {fmt(sum)}</div>}
          <div>Range: {fmt(dataMin)} - {fmt(dataMax)}</div>
          {q1 != null && q3 != null && <div>IQR: {fmt(q1)} - {fmt(q3)}</div>}
          {mean != null && <div>Mean: {fmt(mean)}</div>}
          {median != null && <div>Median: {fmt(median)}</div>}
        </div>
      )}
      <div className={styles.numericInputs}>
        <label>
          <span>Min</span>
          <input
            type="number"
            className={styles.numericInput}
            placeholder="0"
            value={minVal}
            onChange={e => setMinVal(e.target.value)}
            step="any"
            autoFocus
          />
        </label>
        <label>
          <span>Max</span>
          <input
            type="number"
            className={styles.numericInput}
            placeholder="100"
            value={maxVal}
            onChange={e => setMaxVal(e.target.value)}
            step="any"
          />
        </label>
      </div>
      <div className={styles.dropdownFooter}>
        <button className="btn btn-primary" style={{ fontSize: '.78rem', padding: '3px 10px' }}
          onClick={apply}>Apply</button>
        <button className="btn" style={{ fontSize: '.78rem', padding: '3px 10px' }}
          onClick={() => onApply(null, null)}>Clear</button>
      </div>
    </>
  )
}
