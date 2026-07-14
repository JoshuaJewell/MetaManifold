// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useState } from 'react'
import type { CSSProperties } from 'react'
import {
  EditorCard, useEditorActions,
  inputStyle, textareaStyle, fieldLabelStyle, fieldHintStyle,
} from './EditorCard'
import { splitLines } from '../utils/text'
import type { CompositionFilter, CompositionFilterRule } from '../api/types'

interface FilterEditorProps {
  name:     string
  filter:   CompositionFilter
  usedBy:   string[]
  onSave:   (f: CompositionFilter) => Promise<void>
  onDelete: () => Promise<void>
}

type EditableRuleType = 'include' | 'min' | 'max'

//## A fresh rule of the given editable type, ready to be filled in
function blankRule(type: EditableRuleType): CompositionFilterRule {
  return type === 'include'
    ? { column: '', type: 'include', values: [] }
    : { column: '', type, value: 0 }
}

export function FilterEditor({ name, filter, usedBy, onSave, onDelete }: FilterEditorProps) {
  // Rules are kept as the original objects and only patched at the index the
  // user edits. A pattern/regex rule is never patched, so it round-trips
  // byte-for-byte; the same is true of `filter.databases`, spread untouched
  // into the payload on save.
  const [rules, setRules] = useState<CompositionFilterRule[]>(filter.filters ?? [])
  const [removeEmpty, setRemoveEmpty] = useState<string[]>(filter.remove_empty ?? [])

  const { busy, handleSave, handleDelete } = useEditorActions(
    () => onSave({ ...filter, filters: rules, remove_empty: removeEmpty }),
    onDelete,
    `Delete filter "${name}"?`,
  )

  const updateRule = (index: number, patch: Partial<CompositionFilterRule>) => {
    setRules(prev => prev.map((r, i) => (i === index ? { ...r, ...patch } : r)))
  }

  const addRule = (type: EditableRuleType) => {
    setRules(prev => [...prev, blankRule(type)])
  }

  const removeRule = (index: number) => {
    setRules(prev => prev.filter((_, i) => i !== index))
  }

  const inUse = usedBy.length > 0

  return (
    <EditorCard
      name={name}
      meta={inUse ? `Used by: ${usedBy.join(', ')}` : undefined}
      busy={busy}
      deleteDisabled={inUse}
      deleteTitle={inUse ? `In use by: ${usedBy.join(', ')}` : 'Delete this filter'}
      onSave={handleSave}
      onDelete={handleDelete}
    >
      {rules.length === 0 && (
        <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>No rules yet.</p>
      )}

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {rules.map((rule, i) => (
          <RuleRow
            key={i}
            rule={rule}
            onChange={patch => updateRule(i, patch)}
            onRemove={() => removeRule(i)}
          />
        ))}
      </div>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button className="btn" onClick={() => addRule('include')} disabled={busy}>+ Include rule</button>
        <button className="btn" onClick={() => addRule('min')} disabled={busy}>+ Min rule</button>
        <button className="btn" onClick={() => addRule('max')} disabled={busy}>+ Max rule</button>
      </div>

      <label style={fieldLabelStyle}>
        Remove-empty columns
        <span style={fieldHintStyle}>A row missing a value in any of these columns is dropped.</span>
        <textarea
          value={removeEmpty.join('\n')}
          onChange={e => setRemoveEmpty(splitLines(e.target.value))}
          placeholder="One column name per line"
          rows={3}
          disabled={busy}
          style={textareaStyle}
        />
      </label>
    </EditorCard>
  )
}

function RuleRow({ rule, onChange, onRemove }: {
  rule:     CompositionFilterRule
  onChange: (patch: Partial<CompositionFilterRule>) => void
  onRemove: () => void
}) {
  // Pattern/regex rules have no editable fields in this pass of the UI; they
  // are shown for visibility only and are never passed to onChange.
  if (rule.pattern !== undefined) {
    return (
      <div style={{ ...ruleBoxStyle, opacity: .8 }}>
        <div style={{ fontSize: '.8rem', fontWeight: 600, marginBottom: 4 }}>
          {rule.column ?? '(column)'} - pattern rule (read-only)
        </div>
        <p style={fieldHintStyle}>
          Pattern and regex rules are editable only in config/composition.yml. This filter
          keeps the rule unchanged when saved.
        </p>
        <div style={{ fontSize: '.8rem', marginTop: 6, fontFamily: 'monospace' }}>
          pattern: {rule.pattern}
          {rule.action ? `, action: ${rule.action}` : ''}
          {rule.regex ? ', regex' : ''}
        </div>
      </div>
    )
  }

  const type: EditableRuleType = rule.type === 'min' || rule.type === 'max' ? rule.type : 'include'

  return (
    <div style={ruleBoxStyle}>
      <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginBottom: 8 }}>
        <label style={inlineLabelStyle}>Column</label>
        <input
          value={rule.column ?? ''}
          onChange={e => onChange({ column: e.target.value })}
          style={inputStyle}
        />
        <span style={{ fontSize: '.76rem', color: 'var(--color-muted-fg)', textTransform: 'uppercase' }}>
          {type}
        </span>
        <button className="btn" onClick={onRemove} style={{ marginLeft: 'auto' }}>Remove</button>
      </div>

      {type === 'include' && (
        <label style={fieldLabelStyle}>
          Values
          <span style={fieldHintStyle}>One value per line; paste a list freely.</span>
          <textarea
            value={(rule.values ?? []).join('\n')}
            onChange={e => onChange({ values: splitLines(e.target.value) })}
            rows={4}
            style={textareaStyle}
          />
        </label>
      )}

      {(type === 'min' || type === 'max') && (
        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          <label style={inlineLabelStyle}>Value</label>
          <input
            type="number"
            value={rule.value ?? 0}
            onChange={e => onChange({ value: Number(e.target.value) })}
            style={{ ...inputStyle, maxWidth: 140 }}
          />
        </div>
      )}
    </div>
  )
}

const ruleBoxStyle: CSSProperties = {
  border:        '1px solid var(--color-border)',
  borderRadius:  6,
  padding:       '10px 12px',
  background:    'var(--color-surface)',
}

const inlineLabelStyle: CSSProperties = { fontWeight: 600, fontSize: '.82rem', minWidth: 56 }
