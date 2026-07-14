// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { EditorCard, useEditorActions, inputStyle, colourInputStyle } from './EditorCard'
import type { CompositionCategory, CompositionSet } from '../api/types'

interface CategorySetEditorProps {
  name:         string
  set:          CompositionSet
  filterNames:  string[]
  onSave:       (s: CompositionSet) => Promise<void>
  onDelete:     () => Promise<void>
}

// The select's value for "no filter", i.e. the catch-all category.
const CATCH_ALL_VALUE = ''

export function CategorySetEditor({ name, set, filterNames, onSave, onDelete }: CategorySetEditorProps) {
  const [label, setLabel] = useState(set.label ?? '')
  const [description, setDescription] = useState(set.description ?? '')
  const [unassignedColour, setUnassignedColour] = useState(set.unassigned_colour ?? '#95a5a6')
  const [categories, setCategories] = useState<CompositionCategory[]>(set.categories)

  const isProtected = name === 'default'

  const { busy, handleSave, handleDelete } = useEditorActions(
    () => onSave({
      label:             label || undefined,
      description:       description || undefined,
      unassigned_colour: unassignedColour,
      categories,
    }),
    onDelete,
    `Delete category set "${name}"?`,
  )

  const updateCategory = (index: number, patch: Partial<CompositionCategory>) => {
    setCategories(prev => prev.map((c, i) => (i === index ? { ...c, ...patch } : c)))
  }

  //## Order is precedence: swap the category with its neighbour above/below
  const moveCategory = (index: number, direction: -1 | 1) => {
    setCategories(prev => {
      const target = index + direction
      if (target < 0 || target >= prev.length) return prev
      const next = [...prev]
      const tmp = next[index]
      next[index] = next[target]
      next[target] = tmp
      return next
    })
  }

  const addCategory = () => {
    setCategories(prev => [...prev, { name: '', colour: '#4a90d9', filter: filterNames[0] }])
  }

  const removeCategory = (index: number) => {
    setCategories(prev => prev.filter((_, i) => i !== index))
  }

  return (
    <EditorCard
      name={name}
      meta={`${categories.length} categor${categories.length === 1 ? 'y' : 'ies'}`}
      busy={busy}
      deleteDisabled={isProtected}
      deleteTitle={isProtected ? 'The default set cannot be deleted' : 'Delete this category set'}
      onSave={handleSave}
      onDelete={handleDelete}
    >
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        <Field label="Label">
          <input value={label} onChange={e => setLabel(e.target.value)} style={inputStyle} />
        </Field>
        <Field label="Description">
          <input
            value={description}
            onChange={e => setDescription(e.target.value)}
            style={{ ...inputStyle, minWidth: 240 }}
          />
        </Field>
        <Field label="Unassigned colour">
          <input
            type="color"
            value={unassignedColour}
            onChange={e => setUnassignedColour(e.target.value)}
            style={colourInputStyle}
          />
        </Field>
      </div>

      <p style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)' }}>
        First match wins: a sequence is placed in the first category, top to bottom, whose
        filter it satisfies. Reorder these with that in mind; it is not cosmetic.
      </p>

      {categories.length === 0 && (
        <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>No categories yet.</p>
      )}

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {categories.map((cat, i) => (
          <CategoryRow
            key={i}
            category={cat}
            filterNames={filterNames}
            isFirst={i === 0}
            isLast={i === categories.length - 1}
            onChange={patch => updateCategory(i, patch)}
            onMoveUp={() => moveCategory(i, -1)}
            onMoveDown={() => moveCategory(i, 1)}
            onRemove={() => removeCategory(i)}
          />
        ))}
      </div>

      <div>
        <button className="btn" onClick={addCategory} disabled={busy}>+ Category</button>
      </div>
    </EditorCard>
  )
}

function CategoryRow({ category, filterNames, isFirst, isLast, onChange, onMoveUp, onMoveDown, onRemove }: {
  category:   CompositionCategory
  filterNames: string[]
  isFirst:    boolean
  isLast:     boolean
  onChange:   (patch: Partial<CompositionCategory>) => void
  onMoveUp:   () => void
  onMoveDown: () => void
  onRemove:   () => void
}) {
  const isCatchAll = !category.filter

  return (
    <div style={rowStyle}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        <button className="btn" onClick={onMoveUp} disabled={isFirst} style={reorderBtnStyle} title="Move up">^</button>
        <button className="btn" onClick={onMoveDown} disabled={isLast} style={reorderBtnStyle} title="Move down">v</button>
      </div>

      <input
        type="color"
        value={category.colour ?? '#4a90d9'}
        onChange={e => onChange({ colour: e.target.value })}
        style={colourInputStyle}
      />

      <input
        value={category.name}
        onChange={e => onChange({ name: e.target.value })}
        placeholder="Category name"
        style={{ ...inputStyle, maxWidth: 200 }}
      />

      <select
        value={category.filter ?? CATCH_ALL_VALUE}
        onChange={e => onChange({ filter: e.target.value || undefined })}
        style={inputStyle}
      >
        <option value={CATCH_ALL_VALUE}>(none: catch-all)</option>
        {filterNames.map(f => (
          <option key={f} value={f}>{f}</option>
        ))}
      </select>

      {isCatchAll && (
        <span style={badgeStyle} title="Collects every sequence not matched by an earlier category">
          catch-all
        </span>
      )}

      <button className="btn" onClick={onRemove} style={{ marginLeft: 'auto' }}>Remove</button>
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem', fontWeight: 600 }}>
      {label}
      {children}
    </label>
  )
}

const rowStyle: CSSProperties = {
  display:       'flex',
  alignItems:    'center',
  gap:           10,
  border:        '1px solid var(--color-border)',
  borderRadius:  6,
  padding:       '8px 12px',
  background:    'var(--color-surface)',
}

const reorderBtnStyle: CSSProperties = {
  padding:    '0 6px',
  fontSize:   '.7rem',
  lineHeight: 1.4,
}

const badgeStyle: CSSProperties = {
  display:        'inline-block',
  padding:        '2px 8px',
  borderRadius:   10,
  fontSize:       '.72rem',
  fontWeight:     600,
  letterSpacing:  '.03em',
  textTransform:  'uppercase',
  background:     'var(--color-muted-bg)',
  color:          'var(--color-muted-fg)',
  whiteSpace:     'nowrap',
}
