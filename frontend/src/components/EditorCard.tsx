// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
//
// The collapsible card shared by the composition editors: a header that toggles
// the body, and a save/delete footer gated on the same busy flag. FilterEditor
// and CategorySetEditor supply only the fields between the two.
import { useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'

interface EditorCardProps {
  name:            string
  // Right-aligned summary in the header, e.g. "Used by: default" or "4 categories".
  meta?:           ReactNode
  busy:            boolean
  deleteDisabled?: boolean
  deleteTitle?:    string
  onSave:          () => void
  onDelete:        () => void
  children:        ReactNode
}

export function EditorCard({
  name, meta, busy, deleteDisabled = false, deleteTitle, onSave, onDelete, children,
}: EditorCardProps) {
  const [expanded, setExpanded] = useState(false)

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div
        style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }}
        onClick={() => setExpanded(e => !e)}
      >
        <span style={{ fontSize: '.8rem', opacity: .65 }}>{expanded ? 'v' : '>'}</span>
        <strong style={{ flex: 1 }}>{name}</strong>
        {meta && <span style={metaStyle}>{meta}</span>}
      </div>

      {expanded && (
        <div style={{ marginTop: 14, display: 'flex', flexDirection: 'column', gap: 14 }}>
          {children}

          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <button className="btn btn-primary" onClick={onSave} disabled={busy}>
              {busy ? 'Saving...' : 'Save'}
            </button>
            <button
              className="btn"
              onClick={onDelete}
              disabled={busy || deleteDisabled}
              title={deleteTitle}
            >
              Delete
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

/**
 * Busy-gating for a card's save and delete. Both actions reject on a failed
 * write, which CompositionsView has already surfaced via toast; the rejection is
 * swallowed here so it only clears the busy flag. Delete is confirmed first.
 */
export function useEditorActions(
  save: () => Promise<void>,
  remove: () => Promise<void>,
  confirmMessage: string,
) {
  const [busy, setBusy] = useState(false)

  const guarded = async (action: () => Promise<void>) => {
    setBusy(true)
    try {
      await action()
    } catch {
      // CompositionsView already surfaces the error via toast.
    } finally {
      setBusy(false)
    }
  }

  return {
    busy,
    handleSave:   () => { void guarded(save) },
    handleDelete: () => {
      if (!window.confirm(confirmMessage)) return
      void guarded(remove)
    },
  }
}

//## Field styles shared by the editors nested in an EditorCard
export const inputStyle: CSSProperties = {
  flex:          1,
  padding:       '5px 8px',
  border:        '1px solid var(--color-border)',
  borderRadius:  4,
  background:    'var(--color-bg)',
  color:         'var(--color-fg)',
  fontSize:      '.85rem',
  fontFamily:    'inherit',
}

export const textareaStyle: CSSProperties = {
  width:         '100%',
  padding:       '6px 8px',
  border:        '1px solid var(--color-border)',
  borderRadius:  4,
  background:    'var(--color-bg)',
  color:         'var(--color-fg)',
  fontSize:      '.85rem',
  fontFamily:    'inherit',
  resize:        'vertical',
}

export const colourInputStyle: CSSProperties = {
  width:         30,
  height:        26,
  padding:       0,
  border:        '1px solid var(--color-border)',
  borderRadius:  4,
  background:    'none',
  cursor:        'pointer',
}

export const fieldLabelStyle: CSSProperties = {
  display:        'flex',
  flexDirection:  'column',
  gap:            4,
  fontWeight:     600,
  fontSize:       '.82rem',
}

export const fieldHintStyle: CSSProperties = {
  fontWeight:  400,
  fontSize:    '.78rem',
  color:       'var(--color-muted-fg)',
}

// The app's error red, matching .error-msg in styles/app.css. Inline styles
// cannot reach that class, so the value is named here rather than a second red
// being invented at each call site.
export const dangerColour = '#c92a2a'

//## Row-list editing
// Index-based edits over a list of rows, shared by the editors that render one.
export const patchAt = <T,>(items: T[], index: number, patch: Partial<T>): T[] =>
  items.map((row, i) => (i === index ? { ...row, ...patch } : row))

export const removeAt = <T,>(items: T[], index: number): T[] =>
  items.filter((_, i) => i !== index)

export type NameIssue = 'blank' | 'duplicate' | null

/**
 * The name rules the wire format imposes, per row. The document is a name-keyed
 * mapping, so a blank name has nowhere to go and two rows sharing a name would
 * silently collapse into one.
 *
 * This is the single source of the rule: the editor highlights the offending
 * row with it and the view gates Save on it. Expressing it twice let the two
 * normalise differently, so "abc" and "abc " blocked Save while no row was
 * marked, leaving the user unable to see the cause.
 */
export function nameIssues(names: string[]): NameIssue[] {
  const trimmed = names.map(n => n.trim())
  const counts = trimmed.reduce<Record<string, number>>((acc, n) => {
    acc[n] = (acc[n] ?? 0) + 1
    return acc
  }, {})
  return trimmed.map(n => (n === '' ? 'blank' : counts[n] > 1 ? 'duplicate' : null))
}

// The chrome for one editable row in a list of them.
export const editorRowStyle: CSSProperties = {
  display:      'flex',
  alignItems:   'center',
  gap:          10,
  border:       '1px solid var(--color-border)',
  borderRadius: 6,
  padding:      '8px 12px',
  background:   'var(--color-surface)',
}

const metaStyle: CSSProperties = {
  fontSize: '.78rem',
  color:    'var(--color-muted-fg)',
}
