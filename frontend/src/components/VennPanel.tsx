// frontend/src/components/VennPanel.tsx
// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

import { useState, useEffect, useMemo } from 'react'
import { VennDiagram, UpSetJS, asSets } from '@upsetjs/react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from './Toast'
import type { ComparisonRunSpec, VennResult } from '../api/types'
import type { AnalysisOption } from './annotationShared'

type Mode = 'euler' | 'upset'

export function VennPanel({ study, runs, option }: {
  study: string
  runs: ComparisonRunSpec[]
  option: AnalysisOption | null
}) {
  const toast = useToast()
  const [ranks, setRanks]   = useState<string[]>([])
  const [rank, setRank]     = useState<string>('')
  const [mode, setMode]     = useState<Mode>('euler')
  const [result, setResult] = useState<VennResult | null>(null)
  const [loading, setLoading] = useState(false)

  // Discover the intersection of taxonomy ranks available across all selected runs.
  useEffect(() => {
    if (!option || runs.length === 0) { setRanks([]); setRank(''); return }
    let cancelled = false
    const seen = new Set<string>()
    const unique = runs.filter(r => {
      const key = `${r.run}|${r.group ?? ''}`
      if (seen.has(key)) return false
      seen.add(key); return true
    })
    Promise.all(
      unique.map(r =>
        api.analysis.ranks(study, r.run, {
          table: option.table,
          source: option.source,
          group: r.group,
        }).catch(() => [] as string[])
      )
    ).then(results => {
      if (cancelled) return
      const intersection = results.reduce<string[]>((acc, cur) =>
        acc.filter(r => cur.includes(r)),
        results[0] ?? []
      )
      setRanks(intersection)
      // Default to the deepest (last) shared rank.
      setRank(current =>
        intersection.includes(current) ? current : (intersection[intersection.length - 1] ?? '')
      )
    })
    return () => { cancelled = true }
  }, [study, runs, option])

  const runVenn = async () => {
    if (!option || !rank) return
    setLoading(true)
    try {
      const res = await api.analysis.venn(study, {
        runs: runs.map(r => ({ ...r, source: option.source })),
        table: option.table,
        rank,
      })
      setResult(res)
    } catch (err) {
      toast.error(`Taxon overlap failed: ${errorMessage(err)}`)
    } finally {
      setLoading(false)
    }
  }

  const upsetjsSets = useMemo(
    () => result ? asSets(result.sets.map(s => ({ name: s.name, elems: s.taxa }))) : null,
    [result],
  )

  return (
    <div style={{ marginTop: 16 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
        <button
          className="btn"
          onClick={runVenn}
          disabled={loading || !option || !rank}
        >
          {loading ? 'Computing...' : 'Taxon Overlap'}
        </button>

        {ranks.length > 0 && (
          <select
            value={rank}
            onChange={e => setRank(e.target.value)}
            style={{ font: 'inherit', padding: '1px 4px', verticalAlign: 'baseline' }}
          >
            {ranks.map(r => <option key={r} value={r}>{r}</option>)}
          </select>
        )}

        <div style={{
          display: 'flex',
          border: '1px solid var(--color-border)',
          borderRadius: 4,
          overflow: 'hidden',
          height: 26,
        }}>
          <button
            style={{
              padding: '0 10px',
              fontSize: '.8rem',
              background: mode === 'euler' ? 'var(--color-primary, #4C9BE8)' : 'transparent',
              color: mode === 'euler' ? '#fff' : 'inherit',
              border: 'none',
              cursor: 'pointer',
            }}
            onClick={() => setMode('euler')}
          >
            Euler
          </button>
          <button
            style={{
              padding: '0 10px',
              fontSize: '.8rem',
              background: mode === 'upset' ? 'var(--color-primary, #4C9BE8)' : 'transparent',
              color: mode === 'upset' ? '#fff' : 'inherit',
              border: 'none',
              cursor: 'pointer',
            }}
            onClick={() => setMode('upset')}
          >
            UpSet
          </button>
        </div>
      </div>

      {upsetjsSets && (mode === 'euler'
        ? <VennDiagram sets={upsetjsSets} width={580} height={340} />
        : <UpSetJS sets={upsetjsSets} width={580} height={340} />)}
    </div>
  )
}
