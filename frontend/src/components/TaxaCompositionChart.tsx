// (c) 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useEffect, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { ChartCustomiser } from './ChartCustomiser'
import { useToast } from './Toast'
import type { CategorySet, ComparisonRunSpec } from '../api/types'

//## Select / checkbox style tokens (matching ComparisonPanel.tsx)
const SELECT_STYLE: React.CSSProperties = {
  padding: '4px 8px',
  borderRadius: 4,
  border: '1px solid var(--color-border)',
  fontSize: '.82rem',
  background: 'var(--color-bg)',
}

const LABEL_STYLE: React.CSSProperties = {
  fontSize: '.82rem',
  display: 'flex',
  alignItems: 'center',
  gap: 4,
}

export function TaxaCompositionChart({
  study,
  run,
  group,
  runs,
  subgroups,
  defaultTag,
  table,
  subgroup: controlledSubgroup,
}: {
  study: string
  run?: string
  group?: string | null
  runs?: ComparisonRunSpec[]
  subgroups?: string[]
  defaultTag: 'rank' | 'category'
  table?: string
  // When provided (even when null), this value is used as the sub-group for
  // requests and the chart's internal sub-group selector is hidden.
  subgroup?: string | null
}) {
  const toast = useToast()

  //## Tag selector: 'rank' or 'category'
  const [tag, setTag] = useState<'rank' | 'category'>(defaultTag)

  //## Rank state (used when tag='rank')
  const [ranks, setRanks] = useState<string[]>([])
  const [rank, setRank] = useState<string | null>(null)
  const [topN, setTopN] = useState(15)

  //## Category-set state (used when tag='category')
  const [catSets, setCatSets] = useState<CategorySet[]>([])
  const [catSet, setCatSet] = useState<string>('default')

  //## Shared controls
  const [relative, setRelative] = useState(true)
  const [mode, setMode] = useState<'stacked' | 'grouped'>('stacked')
  // null = All, "__pool__" = Pool, any other string = a specific sub-group.
  // When controlledSubgroup is provided, the internal selector is suppressed
  // and this state is ignored in favour of the prop.
  const [internalSubgroup, setInternalSubgroup] = useState<string | null>(null)
  const isControlled = controlledSubgroup !== undefined
  const subgroup = isControlled ? controlledSubgroup : internalSubgroup

  //## Chart state
  const [figure, setFigure] = useState<unknown>(null)
  const [loading, setLoading] = useState(false)

  //## Derived flags
  const isCrossRun = runs !== undefined && runs.length > 0
  // Show the internal sub-group selector only when not controlled externally, and
  // when subgroups has >= 2 entries or we are in cross-run mode.
  const showSubgroupSelector =
    !isControlled && (isCrossRun || (subgroups !== undefined && subgroups.length >= 2))
  const effectiveTable = table ?? 'merged'
  // Stable scalars for the reference run and group, shared by both single-run
  // and cross-run paths. These are primitive values so the rank-fetch effect
  // depends on them without churn from freshly-constructed runs arrays.
  const refRun = run ?? runs?.[0]?.run
  const refGroup = group ?? runs?.[0]?.group

  //## Fetch taxonomy ranks when tag='rank' or the reference run/group changes
  useEffect(() => {
    if (tag !== 'rank') return
    if (!refRun) { setRanks([]); return }
    api.analysis
      .ranks(study, refRun, { table: effectiveTable, group: refGroup ?? undefined })
      .then(result => {
        setRanks(result)
        setRank(current =>
          current && result.includes(current)
            ? current
            : result[result.length - 1] ?? null
        )
      })
      .catch(() => setRanks([]))
  }, [study, refRun, refGroup, tag, effectiveTable])

  //## Fetch category sets when tag='category'
  useEffect(() => {
    if (tag !== 'category') return
    api.composition.categorySets().then(sets => {
      setCatSets(sets)
      setCatSet(current =>
        sets.some(cs => cs.name === current) ? current : sets[0]?.name ?? 'default'
      )
    }).catch(() => {})
  }, [tag])

  //## Compute handler
  const handleShow = async () => {
    const value = tag === 'rank' ? rank : catSet
    if (!value) return
    // Guard: a single-run chart requires a run identifier.
    if (!isCrossRun && run === undefined) {
      toast.error('No run specified')
      return
    }
    setLoading(true)
    try {
      const body = {
        table: effectiveTable,
        tag,
        value,
        relative,
        mode,
        subgroup: subgroup ?? null,
        ...(tag === 'rank' ? { top_n: topN } : {}),
      }
      if (isCrossRun) {
        const result = await api.analysis.chartCompare(study, {
          ...body,
          runs: runs!,
        })
        setFigure(result)
      } else {
        const result = await api.analysis.chart(study, run!, body, group)
        setFigure(result)
      }
    } catch (err) {
      toast.error(`Chart failed: ${errorMessage(err)}`)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div>
      {/* Control strip */}
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
        {/* Tag-by selector */}
        <label style={LABEL_STYLE}>
          Tag by:
          <select
            value={tag}
            onChange={e => setTag(e.target.value as 'rank' | 'category')}
            style={SELECT_STYLE}
          >
            <option value="rank">Rank</option>
            <option value="category">Category</option>
          </select>
        </label>

        {/* Value selector: ranks when tag='rank', category sets when tag='category' */}
        {tag === 'rank' ? (
          <select
            value={rank ?? ''}
            onChange={e => setRank(e.target.value)}
            style={SELECT_STYLE}
          >
            {ranks.map(r => <option key={r} value={r}>{r}</option>)}
          </select>
        ) : (
          <select
            value={catSet}
            onChange={e => setCatSet(e.target.value)}
            style={SELECT_STYLE}
          >
            {catSets.map(cs => <option key={cs.name} value={cs.name}>{cs.label}</option>)}
          </select>
        )}

        {/* top_n: shown only when tag='rank' */}
        {tag === 'rank' && (
          <label style={LABEL_STYLE}>
            Top N:
            <input
              type="number"
              min={1}
              max={100}
              value={topN}
              onChange={e => {
                const n = parseInt(e.target.value, 10)
                setTopN(Number.isNaN(n) ? 15 : n)
              }}
              style={{
                width: 52,
                padding: '3px 6px',
                borderRadius: 4,
                border: '1px solid var(--color-border)',
                fontSize: '.82rem',
              }}
            />
          </label>
        )}

        {/* Relative checkbox */}
        <label style={LABEL_STYLE}>
          <input
            type="checkbox"
            checked={relative}
            onChange={e => setRelative(e.target.checked)}
          />
          Relative
        </label>

        {/* Stacked / Grouped selector */}
        <select
          value={mode}
          onChange={e => setMode(e.target.value as 'stacked' | 'grouped')}
          style={SELECT_STYLE}
        >
          <option value="stacked">Stacked</option>
          <option value="grouped">Grouped</option>
        </select>

        {/* Internal sub-group selector: hidden when the prop controls the value */}
        {showSubgroupSelector && (
          <select
            value={internalSubgroup ?? ''}
            onChange={e => setInternalSubgroup(e.target.value || null)}
            style={SELECT_STYLE}
          >
            <option value="">All</option>
            {(subgroups ?? []).map(sg => (
              <option key={sg} value={sg}>{sg}</option>
            ))}
            <option value="__pool__">Pool</option>
          </select>
        )}

        {/* Compute button */}
        <button
          className="btn btn-primary"
          onClick={handleShow}
          disabled={loading || (tag === 'rank' ? !rank : !catSet)}
        >
          {loading ? 'Computing...' : 'Show'}
        </button>
      </div>

      {/* Chart output */}
      {figure != null && (
        <ChartCustomiser
          study={study}
          chartType={tag === 'rank' ? 'taxa_bar' : 'composition'}
          figure={figure}
          heightRatio={0.3}
        />
      )}
    </div>
  )
}
