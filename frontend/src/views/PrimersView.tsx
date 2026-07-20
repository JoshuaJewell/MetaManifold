// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from '../components/Toast'
import { Skeleton } from '../components/Skeleton'
import { PrimerListEditor, nameIssues } from '../components/PrimerListEditor'
import type { PrimerRow } from '../components/PrimerListEditor'
import { PairEditor } from '../components/PairEditor'
import type { PrimerDocument, PrimerPair } from '../api/types'

// The wire format keys primers by name; the editor holds them as ordered rows
// with a stable id. A name is edited text, so it cannot double as the
// collection key: keying by it collapses two rows into one the moment a name
// is half-typed into an existing one, silently destroying a primer.
function toRows(primers: Record<string, string>, offset: number): PrimerRow[] {
  return Object.entries(primers).map(([name, seq], i) => ({ id: offset + i, name, seq }))
}

function toMap(rows: PrimerRow[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (const r of rows) out[r.name] = r.seq
  return out
}

export function PrimersView() {
  const toast = useToast()
  const fetcher = useCallback(() => api.primers.document(), [])
  const { data, loading, error } = useApi(fetcher)

  const [forward, setForward] = useState<PrimerRow[]>([])
  const [reverse, setReverse] = useState<PrimerRow[]>([])
  const [pairs, setPairs]     = useState<PrimerPair[]>([])
  const [busy, setBusy]       = useState(false)
  const [dirty, setDirty]     = useState(false)

  const load = useCallback((doc: PrimerDocument) => {
    // Forward and reverse ids share one space so a row id is unique per view.
    setForward(toRows(doc.Forward, 0))
    setReverse(toRows(doc.Reverse, Object.keys(doc.Forward).length))
    setPairs(doc.Pairs)
    setDirty(false)
  }, [])

  useEffect(() => { data && load(data) }, [data, load])

  // Renaming a primer must carry its pairs with it, or the save is rejected for
  // naming a primer that no longer exists and the user must re-point each pair
  // by hand. Renames are matched by row id, which survives the edit.
  //
  // The rows arrive one edit at a time, so the common keystroke (typing into a
  // sequence) leaves every name untouched. Comparing lengths and names
  // positionally first keeps that case out of the id-matching scan entirely.
  const renameInPairs = (before: PrimerRow[], after: PrimerRow[], side: 'forward' | 'reverse') => {
    if (before.length === after.length &&
        before.every((b, i) => b.id === after[i].id && b.name === after[i].name)) return
    const moved = new Map<string, string>()
    const byId = new Map(after.map(r => [r.id, r]))
    for (const b of before) {
      const a = byId.get(b.id)
      a && a.name !== b.name && moved.set(b.name, a.name)
    }
    moved.size > 0 && setPairs(prev => prev.map(p => {
      const next = moved.get(p[side])
      return next === undefined ? p : { ...p, [side]: next }
    }))
  }

  const changeForward = (next: PrimerRow[]) => {
    renameInPairs(forward, next, 'forward')
    setForward(next); setDirty(true)
  }
  const changeReverse = (next: PrimerRow[]) => {
    renameInPairs(reverse, next, 'reverse')
    setReverse(next); setDirty(true)
  }
  const changePairs = (next: PrimerPair[]) => { setPairs(next); setDirty(true) }

  // A blank or duplicated name would collapse rows when the document is keyed by
  // name, so Save is withheld until the user resolves it. The server remains the
  // authority on everything else; this only guards what the wire format cannot
  // represent. `nameIssues` is the same rule the editors highlight rows with, so
  // a blocked Save always has a marked row explaining it.
  const nameProblem = useMemo(() => {
    const groups = [
      ['forward primer', forward.map(r => r.name)],
      ['reverse primer', reverse.map(r => r.name)],
      ['pair',           pairs.map(p => p.name)],
    ] as const
    for (const [label, names] of groups) {
      const issues = nameIssues(names)
      if (issues.includes('blank'))     return `A ${label} has no name.`
      if (issues.includes('duplicate')) return `Two ${label}s share a name.`
    }
    return null
  }, [forward, reverse, pairs])

  const handleSave = async () => {
    if (nameProblem) return
    setBusy(true)
    try {
      const res = await api.primers.save({
        Forward: toMap(forward), Reverse: toMap(reverse), Pairs: pairs,
      })
      load(res.document)
      toast.success('Primers saved')
      // The save succeeded; a warning is advisory, so it is reported as info
      // rather than as an error the user might read as a failure.
      for (const w of res.warnings) {
        toast.info(`Saved. Pair "${w.pair}" is still referenced by: ${w.referenced_by.join(', ')}`)
      }
    } catch (err) {
      toast.error(errorMessage(err, 'Failed to save primers'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <div className="page-header">
        <h1>Primers</h1>
        <p>
          Define the forward and reverse primers and the pairs composed from them. Editing here
          replaces hand-editing config/primers.yml. Removing or renaming a pair a study still
          references is allowed, but you will be told which studies it affects.
        </p>
      </div>

      {loading && <Skeleton lines={4} />}
      {error && <p className="error-msg">{error}</p>}

      {data && (
        <>
          <PrimerListEditor
            title="Forward primers"
            rows={forward}
            onChange={changeForward}
            disabled={busy}
          />
          <PrimerListEditor
            title="Reverse primers"
            rows={reverse}
            onChange={changeReverse}
            disabled={busy}
          />
          <PairEditor
            pairs={pairs}
            forwardNames={forward.map(r => r.name)}
            reverseNames={reverse.map(r => r.name)}
            onChange={changePairs}
            disabled={busy}
          />

          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            <button className="btn btn-primary" onClick={handleSave} disabled={busy || nameProblem !== null}>
              {busy ? 'Saving...' : 'Save'}
            </button>
            {nameProblem && <span className="error-msg" style={{ margin: 0 }}>{nameProblem}</span>}
            {!nameProblem && dirty && (
              <span style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)' }}>Unsaved changes.</span>
            )}
          </div>
        </>
      )}
    </>
  )
}
