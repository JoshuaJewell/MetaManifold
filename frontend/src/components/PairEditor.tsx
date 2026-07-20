// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { inputStyle, editorRowStyle, patchAt, removeAt } from './EditorCard'
import type { PrimerPair } from '../api/types'

export interface PairEditorProps {
  pairs:         PrimerPair[]
  forwardNames:  string[]
  reverseNames:  string[]
  onChange:      (next: PrimerPair[]) => void
  disabled:      boolean
}

export function PairEditor({ pairs, forwardNames, reverseNames, onChange, disabled }: PairEditorProps) {
  const add = () => onChange([...pairs, {
    name: '', forward: forwardNames[0] ?? '', reverse: reverseNames[0] ?? '',
  }])

  return (
    <section style={{ marginBottom: 20 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <h3 style={{ fontSize: '.95rem', fontWeight: 700 }}>Pairs</h3>
        <button className="btn" onClick={add} disabled={disabled}>+ Pair</button>
      </div>
      {pairs.length === 0 && <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>No pairs defined.</p>}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {pairs.map((p, i) => {
          const fwdMissing = p.forward !== '' && !forwardNames.includes(p.forward)
          const revMissing = p.reverse !== '' && !reverseNames.includes(p.reverse)
          return (
            <div key={i} style={editorRowStyle}>
              <input
                value={p.name}
                onChange={e => onChange(patchAt(pairs, i, { name: e.target.value }))}
                placeholder="Pair name"
                style={{ ...inputStyle, maxWidth: 160 }}
                disabled={disabled}
              />
              <select value={p.forward} onChange={e => onChange(patchAt(pairs, i, { forward: e.target.value }))} style={inputStyle} disabled={disabled}>
                {fwdMissing && <option value={p.forward}>{p.forward} (missing)</option>}
                {/* A primer name is edited text, so it cannot key these options; the
                    index can, an option carrying no state that a remount would lose. */}
                {forwardNames.map((n, j) => <option key={j} value={n}>{n}</option>)}
              </select>
              <select value={p.reverse} onChange={e => onChange(patchAt(pairs, i, { reverse: e.target.value }))} style={inputStyle} disabled={disabled}>
                {revMissing && <option value={p.reverse}>{p.reverse} (missing)</option>}
                {reverseNames.map((n, j) => <option key={j} value={n}>{n}</option>)}
              </select>
              <button className="btn" onClick={() => onChange(removeAt(pairs, i))} disabled={disabled} style={{ marginLeft: 'auto' }}>Remove</button>
            </div>
          )
        })}
      </div>
    </section>
  )
}
