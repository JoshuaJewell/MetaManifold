// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from '../components/Toast'
import { Skeleton } from '../components/Skeleton'
import { inputStyle, fieldLabelStyle, fieldHintStyle, patchAt, removeAt, nameIssues } from '../components/EditorCard'
import { DatabaseEditor, emptyDatabaseRow, nextId, toDatabaseEntries, toDatabaseRows } from '../components/DatabaseEditor'
import type { DatabaseRow } from '../components/DatabaseEditor'
import type { DatabaseDocument, DatabaseEntry, DatabaseWarning } from '../api/types'

// A version token the server could not read out of a URI's basename arrives as
// an empty string, which would otherwise render as a gap in the sentence.
const versionOr = (v: string | undefined) => (v === undefined || v === '' ? 'no version in its URI' : v)

// One readable sentence per warning kind. Every one of them reports a save that
// already succeeded, so each opens by saying so.
function warningMessage(w: DatabaseWarning): string {
  const usedBy = (w.used_by ?? []).join(', ')
  switch (w.kind) {
    case 'database_removed':
      return `Saved. Database "${w.database}" is no longer in the configuration, whether removed or renamed, but these projects still resolve to it: ${usedBy}.`
    case 'levels_changed':
      return `Saved. The taxonomy levels of database "${w.database}" changed, which shifts its taxonomy columns for these projects: ${usedBy}.`
    case 'release_mismatch':
      return `Saved. Database "${w.database}" draws its two formats from different releases: DADA2 ${versionOr(w.dada2_version)}, VSEARCH ${versionOr(w.vsearch_version)}. The consensus rank compares the two labels for equality, so a mixed pair scores genuine agreements as disagreements.`
  }
}

export function DatabasesView() {
  const toast = useToast()

  const listFetcher = useCallback(() => api.databases.list(), [])
  const { data: dbs, loading: listLoading, error: listError, refetch: refetchList } = useApi(listFetcher)

  const docFetcher = useCallback(() => api.databases.document(), [])
  const { data: doc, loading: docLoading, error: docError } = useApi(docFetcher)

  const [dir, setDir]   = useState('')
  const [rows, setRows] = useState<DatabaseRow[]>([])
  const [busy, setBusy] = useState(false)
  const [dirty, setDirty] = useState(false)

  const load = useCallback((d: DatabaseDocument) => {
    setDir(d.dir)
    setRows(toDatabaseRows(d.databases))
    setDirty(false)
  }, [])

  useEffect(() => { doc && load(doc) }, [doc, load])

  const changeDir = (next: string) => { setDir(next); setDirty(true) }
  const changeRow = (i: number, next: DatabaseRow) => { setRows(patchAt(rows, i, next)); setDirty(true) }
  const removeRow = (i: number) => { setRows(removeAt(rows, i)); setDirty(true) }
  const addRow    = () => { setRows([...rows, emptyDatabaseRow(nextId(rows))]); setDirty(true) }

  // The fault in each database's name, computed once. The editor marks its row
  // with the entry from this array and Save is withheld on the same array, so a
  // blocked Save always has a marked row explaining it. Expressing the rule twice
  // let the two normalise differently and left the user unable to see the cause;
  // see the note on nameIssues.
  const keyProblems = useMemo(() => {
    const issues = nameIssues(rows.map(r => r.key))
    return rows.map((r, i) =>
      issues[i] === 'blank'     ? 'A name is required.'
      : issues[i] === 'duplicate' ? 'Two databases share this name.'
      // `dir` is the cache directory and shares the entries' namespace on disk, so
      // a database of that name would silently become the cache path. The server
      // rejects it; catching it here marks the row rather than bouncing the save.
      : r.key.trim() === 'dir'    ? 'The name "dir" is reserved for the cache directory.'
      : null)
  }, [rows])

  // A blank level name is meaningless and yields a taxonomy column of no name; a
  // level duplicated after trimming is one rank spelt twice, so the second is a
  // silent no-op. The levels editor has always marked both red with `nameIssues`,
  // but Save was not withheld on them and the server accepted them, so the user
  // saved successfully DESPITE a red field. The server now rejects both; gating
  // here on the same rule is what makes mark, gate and backend agree.
  const levelProblem = useMemo(() => {
    for (const row of rows) {
      const issues = nameIssues(row.levels.map(l => l.name))
      if (issues.includes('blank')) return `A taxonomy level in database "${row.key}" has no name.`
      if (issues.includes('duplicate')) return `Two taxonomy levels in database "${row.key}" share a name.`
    }
    return null
  }, [rows])

  // A correction value's `from` re-keys the native mapping on save, so the same
  // hazard as a database name reappears one level down: a blank `from` has
  // nowhere to go and two rows sharing one collapse into a single entry. The
  // editor marks the offending row with the same `nameIssues` rule, so a blocked
  // Save always has a marked row explaining it.
  const correctionProblem = useMemo(() => {
    for (const row of rows) {
      for (const correction of row.corrections) {
        const issues = nameIssues(correction.values.map(v => v.from))
        if (issues.includes('blank')) return `A correction value in database "${row.key}" has no source label.`
        if (issues.includes('duplicate')) return `Two correction values in database "${row.key}" share a source label.`
      }
    }
    return null
  }, [rows])

  const saveProblem = useMemo(
    () => keyProblems.find(p => p !== null) ?? levelProblem ?? correctionProblem,
    [keyProblems, levelProblem, correctionProblem],
  )

  const handleSave = async () => {
    if (saveProblem) return
    setBusy(true)
    try {
      const res = await api.databases.save({ dir, databases: toDatabaseEntries(rows) })
      load(res.document)
      toast.success('Databases saved')
      // The save succeeded; a warning is advisory, so it is reported as info
      // rather than as an error the user might read as a failure.
      for (const w of res.warnings) toast.info(warningMessage(w))
      // The badges below describe the saved config, which has just changed.
      refetchList()
    } catch (err) {
      toast.error(errorMessage(err, 'Failed to save databases'))
    } finally {
      setBusy(false)
    }
  }

  const download = async (key: string) => {
    try {
      await api.databases.download(key)
      toast.info(`Download of "${key}" queued. Watch it on the Jobs page.`)
      refetchList()
    } catch (err) {
      toast.error(errorMessage(err, `Failed to start the download of "${key}"`))
    }
  }

  return (
    <>
      <div className="page-header">
        <h1>Databases</h1>
        <p>
          The reference databases taxonomy assignment draws on. Editing here replaces hand-editing
          config/databases.yml. Renaming or removing a database a study still resolves to is allowed,
          but you will be told which studies it affects.
        </p>
      </div>

      {(docLoading || listLoading) && <Skeleton lines={4} />}
      {docError && <p className="error-msg">{docError}</p>}

      {doc && (
        <>
          <label style={{ ...fieldLabelStyle, maxWidth: 480, marginBottom: 20 }}>
            Cache directory
            <input
              value={dir}
              onChange={e => changeDir(e.target.value)}
              placeholder="./databases"
              style={{ ...inputStyle, fontFamily: 'monospace', fontSize: '.8rem' }}
              disabled={busy}
            />
            <span style={fieldHintStyle}>
              Where downloads are cached, shared by every database. Absolute, or relative to the
              working directory.
            </span>
          </label>

          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
            <h2 style={{ fontSize: '1rem', fontWeight: 700 }}>Configured databases</h2>
            <button className="btn" onClick={addRow} disabled={busy}>+ Database</button>
          </div>

          {rows.length === 0 && (
            <div className="empty-state">No databases configured.</div>
          )}

          {rows.map((row, i) => (
            <DatabaseEditor
              key={row.id}
              row={row}
              keyProblem={keyProblems[i]}
              onChange={next => changeRow(i, next)}
              onRemove={() => removeRow(i)}
              disabled={busy}
            />
          ))}

          <div style={{ display: 'flex', gap: 12, alignItems: 'center', marginTop: 16 }}>
            <button className="btn btn-primary" onClick={handleSave} disabled={busy || saveProblem !== null}>
              {busy ? 'Saving...' : 'Save'}
            </button>
            {saveProblem && <span className="error-msg" style={{ margin: 0 }}>{saveProblem}</span>}
            {!saveProblem && dirty && (
              <span style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)' }}>Unsaved changes.</span>
            )}
          </div>
        </>
      )}

      <section style={{ marginTop: 32 }}>
        <h2 style={{ fontSize: '1rem', fontWeight: 700, marginBottom: 4 }}>Availability</h2>
        {/* These badges are read from the saved config, so while the editor is
            dirty they can speak neither for the URI on screen nor for anything
            downloaded from it. They are greyed and the download withheld rather
            than shown as though they were live. */}
        <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)', marginBottom: 10 }}>
          {dirty
            ? 'Stale: these describe the saved configuration, not your unsaved edits. Save to refresh them.'
            : 'Whether each configured file is already on disk. A download fetches the source URI into the cache directory.'}
        </p>

        {listError && <p className="error-msg">{listError}</p>}

        {dbs && dbs.length === 0 && (
          <div className="empty-state">Nothing configured to download.</div>
        )}

        {dbs && dbs.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, opacity: dirty ? .5 : 1 }}>
            {dbs.map((db: DatabaseEntry) => (
              <div key={db.key} className="card" style={{ display: 'grid', gridTemplateColumns: '1fr auto', alignItems: 'center', gap: 12 }}>
                <div>
                  <strong>{db.label}</strong>
                  <div style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>
                    DADA2: {db.dada2_available ? 'available' : 'not downloaded'}
                    {' - '}
                    vsearch: {db.vsearch_available ? 'available' : 'not downloaded'}
                  </div>
                </div>
                {(!db.dada2_available || !db.vsearch_available) && (
                  <button
                    className="btn btn-primary"
                    onClick={() => download(db.key)}
                    disabled={dirty || busy}
                    title={dirty ? 'Save your changes first: a download reads the saved configuration.' : undefined}
                  >
                    Download
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </section>
    </>
  )
}
