// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { inputStyle, editorRowStyle, dangerColour, patchAt, removeAt, nameIssues } from './EditorCard'
export { nameIssues } from './EditorCard'
export type { NameIssue } from './EditorCard'

// Valid IUPAC nucleotide codes, case-insensitive. Mirrors the server rule so an
// illegal base is flagged inline before Save rather than bouncing off a 400.
// A sequence must have at least one base: an empty one passes the server's
// character check vacuously, and would reach cutadapt as an empty primer.
const IUPAC = /^[ACGTMRWSYKVHDBNacgtmrwsykvhdbn]+$/

export interface PrimerRow {
  // Identity for React, stable across renames. The name is edited text and so
  // cannot serve as the key: keying by it remounts the input on every keystroke
  // and drops focus.
  id:   number
  name: string
  seq:  string
}

export interface PrimerListEditorProps {
  title:    string
  // Ordered name/sequence rows. The parent holds primers as an ordered list
  // rather than a map, so a half-typed or duplicated name cannot collapse two
  // rows into one; see PrimersView.
  rows:     PrimerRow[]
  onChange: (next: PrimerRow[]) => void
  disabled: boolean
}

export function PrimerListEditor({ title, rows, onChange, disabled }: PrimerListEditorProps) {
  const add = () => {
    const nextId = rows.reduce((m, r) => Math.max(m, r.id), 0) + 1
    onChange([...rows, { id: nextId, name: '', seq: '' }])
  }
  const issues = nameIssues(rows.map(r => r.name))

  return (
    <section style={{ marginBottom: 20 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <h3 style={{ fontSize: '.95rem', fontWeight: 700 }}>{title}</h3>
        <button className="btn" onClick={add} disabled={disabled}>+ Primer</button>
      </div>
      {rows.length === 0 && <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>None defined.</p>}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {rows.map((row, i) => {
          const badBase   = !IUPAC.test(row.seq)
          const nameIssue = issues[i]
          const problem   = nameIssue === 'blank'     ? 'name required'
                          : nameIssue === 'duplicate' ? 'duplicate name'
                          : badBase                   ? 'invalid base'
                          : null
          return (
            <div key={row.id} style={editorRowStyle}>
              <input
                value={row.name}
                onChange={e => onChange(patchAt(rows, i, { name: e.target.value }))}
                placeholder="Primer name"
                style={{ ...inputStyle, maxWidth: 160, borderColor: nameIssue ? dangerColour : undefined }}
                disabled={disabled}
              />
              <input
                value={row.seq}
                onChange={e => onChange(patchAt(rows, i, { seq: e.target.value }))}
                placeholder="IUPAC sequence"
                style={{ ...inputStyle, fontFamily: 'monospace', borderColor: badBase ? dangerColour : undefined }}
                disabled={disabled}
              />
              {problem && <span style={{ fontSize: '.75rem', color: dangerColour, whiteSpace: 'nowrap' }}>{problem}</span>}
              <button className="btn" onClick={() => onChange(removeAt(rows, i))} disabled={disabled} style={{ marginLeft: 'auto' }}>Remove</button>
            </div>
          )
        })}
      </div>
    </section>
  )
}
