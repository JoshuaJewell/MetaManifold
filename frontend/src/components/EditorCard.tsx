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

const metaStyle: CSSProperties = {
  fontSize: '.78rem',
  color:    'var(--color-muted-fg)',
}
