// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
//
// One reference database from config/databases.yml: its name and label, the two
// format blocks, the ordered taxonomy levels, the vsearch parser format and the
// taxonomy corrections. DatabasesView owns the document and the single Save; this
// component only edits the entry handed to it.
import { useState } from 'react'
import type { CSSProperties } from 'react'
import {
  inputStyle, editorRowStyle, dangerColour, fieldLabelStyle, fieldHintStyle,
  patchAt, removeAt, nameIssues,
} from './EditorCard'
import type { DatabaseDocumentEntry, DatabaseFormat } from '../api/types'

//## The editor's row model
// Every editable list here is ordered rows with a stable numeric id, never a map
// and never a list keyed by the text being edited. The primers slice proved the
// alternative destroys data: keying rows by their edited name collapses {F1, F2}
// into one row the moment F1 is renamed towards F2, reachable merely by typing,
// since "F2" passes through the transient name "F"; it also remounts the input on
// every keystroke and so drops focus. Levels, corrections and correction values
// each carry that same hazard, so each gets ids.
export interface LevelRow {
  id:   number
  name: string
}

export interface ValueRow {
  id:   number
  from: string
  to:   string
}

export interface CorrectionRow {
  id:     number
  source: string
  target: string
  values: ValueRow[]
}

export interface DatabaseRow {
  id:             number
  key:            string
  label:          string
  dada2:          DatabaseFormat
  vsearch:        DatabaseFormat
  levels:         LevelRow[]
  vsearch_format: string
  corrections:    CorrectionRow[]
}

// An id need only be unique among its siblings: a React key is scoped to the one
// list it is rendered in, so each list numbers its own rows from zero.
export const nextId = (rows: { id: number }[]): number =>
  rows.reduce((m, r) => Math.max(m, r.id), 0) + 1

export function toDatabaseRows(entries: DatabaseDocumentEntry[]): DatabaseRow[] {
  return entries.map((e, i) => ({
    id:             i,
    key:            e.key,
    label:          e.label,
    dada2:          e.dada2,
    vsearch:        e.vsearch,
    levels:         e.levels.map((name, j) => ({ id: j, name })),
    vsearch_format: e.vsearch_format,
    corrections:    e.corrections.map((c, j) => ({
      id:     j,
      source: c.source,
      target: c.target,
      values: c.values.map((v, k) => ({ id: k, from: v.from, to: v.to })),
    })),
  }))
}

// Back to the wire format. The ids are the editor's own bookkeeping and never
// reach the server.
export function toDatabaseEntries(rows: DatabaseRow[]): DatabaseDocumentEntry[] {
  return rows.map(r => ({
    key:            r.key,
    label:          r.label,
    dada2:          r.dada2,
    vsearch:        r.vsearch,
    levels:         r.levels.map(l => l.name),
    vsearch_format: r.vsearch_format,
    corrections:    r.corrections.map(c => ({
      source: c.source,
      target: c.target,
      values: c.values.map(v => ({ from: v.from, to: v.to })),
    })),
  }))
}

export function emptyDatabaseRow(id: number): DatabaseRow {
  return {
    id,
    key:            '',
    label:          '',
    dada2:          { uri: '', local: null, remote_path: null },
    vsearch:        { uri: '', local: null },
    levels:         [],
    vsearch_format: 'generic',
    corrections:    [],
  }
}

//## Ordered-list editing
// The levels are ordered and the order is load-bearing, so a row must be movable
// without being retyped. patchAt and removeAt cover the rest.
function moveAt<T>(items: T[], from: number, to: number): T[] {
  if (to < 0 || to >= items.length) return items
  const next = items.slice()
  const [row] = next.splice(from, 1)
  next.splice(to, 0, row)
  return next
}

// Renaming a level must carry its corrections with it, or the save is rejected
// for naming a level the database no longer has and the user must re-point each
// correction by hand; the correction's select goes red on the very first
// keystroke of the rename. Renames are matched by row id, which survives the
// edit. The sibling of PrimersView's renameInPairs, and the same shape.
//
// The short-circuit is that function's: a positional comparison of ids and
// names, cheaper than the id-matching scan and covering every edit that renames
// nothing.
export function renameInCorrections(
  before: LevelRow[], after: LevelRow[], corrections: CorrectionRow[],
): CorrectionRow[] {
  if (before.length === after.length &&
      before.every((b, i) => b.id === after[i].id && b.name === after[i].name)) return corrections
  const moved = new Map<string, string>()
  const byId = new Map(after.map(r => [r.id, r]))
  for (const b of before) {
    const a = byId.get(b.id)
    a && a.name !== b.name && moved.set(b.name, a.name)
  }
  if (moved.size === 0) return corrections
  return corrections.map(c => ({
    ...c,
    source: moved.get(c.source) ?? c.source,
    target: moved.get(c.target) ?? c.target,
  }))
}

//## vsearch_format
// The only two values the pipeline distinguishes. make_db_meta reads anything it
// does not recognise as "generic" and only the literal "pr2" selects
// pipe-separated parsing, so a typed "PR2" would parse every header generically
// and mislabel every taxonomic assignment. A select is the guard; this field is
// never free text.
const VSEARCH_FORMATS: readonly string[] = ['pr2', 'generic']

//## One database entry
export interface DatabaseEditorProps {
  row: DatabaseRow
  // The fault in this row's name, or null. The view computes it across every
  // database and gates Save on the same array, so a blocked Save and the marked
  // row can never disagree about what is wrong.
  keyProblem: string | null
  onChange:   (next: DatabaseRow) => void
  onRemove:   () => void
  disabled:   boolean
}

export function DatabaseEditor({ row, keyProblem, onChange, onRemove, disabled }: DatabaseEditorProps) {
  const [expanded, setExpanded] = useState(true)
  const set = (patch: Partial<DatabaseRow>) => onChange({ ...row, ...patch })

  const levelNames    = row.levels.map(l => l.name)
  const unknownFormat = !VSEARCH_FORMATS.includes(row.vsearch_format)

  const addCorrection = () => set({
    corrections: [...row.corrections, {
      id:     nextId(row.corrections),
      source: levelNames[0] ?? '',
      target: levelNames[0] ?? '',
      values: [],
    }],
  })

  return (
    <div className="card">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button
          className="btn"
          style={{ padding: '2px 9px' }}
          onClick={() => setExpanded(e => !e)}
          title={expanded ? 'Collapse' : 'Expand'}
        >
          {expanded ? 'v' : '>'}
        </button>
        <strong style={{ flex: 1 }}>{row.key.trim() === '' ? '(unnamed database)' : row.key}</strong>
        {row.label.trim() !== '' && <span style={metaStyle}>{row.label}</span>}
        <button className="btn" onClick={onRemove} disabled={disabled}>Remove</button>
      </div>

      {expanded && (
        <div style={{ marginTop: 16, display: 'flex', flexDirection: 'column', gap: 18 }}>
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            <label style={{ ...fieldLabelStyle, flex: 1, minWidth: 220 }}>
              Name
              <input
                value={row.key}
                onChange={e => set({ key: e.target.value })}
                placeholder="Database name"
                style={{ ...inputStyle, borderColor: keyProblem ? dangerColour : undefined }}
                disabled={disabled}
              />
              <span style={keyProblem ? problemStyle : fieldHintStyle}>
                {keyProblem ?? 'The name a study names in dada2.taxonomy.database.'}
              </span>
            </label>
            <label style={{ ...fieldLabelStyle, flex: 1, minWidth: 220 }}>
              Label
              <input
                value={row.label}
                onChange={e => set({ label: e.target.value })}
                placeholder="Human-readable label"
                style={inputStyle}
                disabled={disabled}
              />
              <span style={fieldHintStyle}>Shown in the availability list below.</span>
            </label>
          </div>

          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap' }}>
            <FormatEditor
              title="DADA2 reference"
              format={row.dada2}
              unresolved={formatUnresolved(row.dada2)}
              remote
              onChange={next => set({ dada2: next })}
              disabled={disabled}
            />
            <FormatEditor
              title="VSEARCH reference"
              format={row.vsearch}
              unresolved={formatUnresolved(row.vsearch)}
              onChange={next => set({ vsearch: next })}
              disabled={disabled}
            />
          </div>

          <label style={{ ...fieldLabelStyle, maxWidth: 420 }}>
            VSEARCH header format
            <select
              value={row.vsearch_format}
              onChange={e => set({ vsearch_format: e.target.value })}
              style={{ ...inputStyle, borderColor: unknownFormat ? dangerColour : undefined }}
              disabled={disabled}
            >
              {unknownFormat && <option value={row.vsearch_format}>{row.vsearch_format} (unrecognised)</option>}
              <option value="pr2">pr2 (pipe-separated PR2 headers)</option>
              <option value="generic">generic</option>
            </select>
            <span style={unknownFormat ? problemStyle : fieldHintStyle}>
              {unknownFormat
                ? 'The pipeline does not recognise this value and would read it as generic. Choose pr2 or generic.'
                : 'Only the exact value pr2 selects pipe-separated parsing; anything else is read as generic.'}
            </span>
          </label>

          <LevelsEditor
            levels={row.levels}
            onChange={next => set({
              levels: next,
              corrections: renameInCorrections(row.levels, next, row.corrections),
            })}
            disabled={disabled}
          />

          <section>
            <div style={sectionHeadStyle}>
              <h4 style={subheadingStyle}>Corrections</h4>
              <button className="btn" onClick={addCorrection} disabled={disabled}>+ Correction</button>
            </div>
            <p style={{ ...fieldHintStyle, marginBottom: 8 }}>
              A correction rewrites a taxon label from one rank into another. Both ranks must be
              levels of this database; the server rejects the save otherwise.
            </p>
            {row.corrections.length === 0 && <p style={emptyStyle}>None defined.</p>}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {row.corrections.map((c, i) => (
                <CorrectionEditor
                  key={c.id}
                  correction={c}
                  levelNames={levelNames}
                  onChange={next => set({ corrections: patchAt(row.corrections, i, next) })}
                  onRemove={() => set({ corrections: removeAt(row.corrections, i) })}
                  disabled={disabled}
                />
              ))}
            </div>
          </section>
        </div>
      )}
    </div>
  )
}

//## One format block
interface FormatEditorProps {
  title:  string
  format: DatabaseFormat
  // Whether this format names neither a uri nor a local path, and so can never
  // resolve. The server rejects the save for it; it is marked here so this rule
  // marks its row like every other one rather than only reaching the user as a
  // toast after a bounced Save.
  unresolved: boolean
  // remote_path is a DADA2-only field: the vsearch stage has no remote host.
  remote?:  boolean
  onChange: (next: DatabaseFormat) => void
  disabled: boolean
}

// A format resolves from a uri or from a local path; with neither it names
// nothing to fetch and nothing on disk. This is the same rule the server applies
// at the write gate, spelt once here and used both to mark the fields and to
// withhold Save.
export const formatUnresolved = (f: DatabaseFormat): boolean =>
  f.uri.trim() === '' && (f.local ?? '').trim() === ''

function FormatEditor({ title, format, unresolved, remote = false, onChange, disabled }: FormatEditorProps) {
  const set = (patch: Partial<DatabaseFormat>) => onChange({ ...format, ...patch })
  // An absent path is null, not "": the wire format spells absence as null and an
  // empty string would land in the YAML as a path of no characters. The value is
  // trimmed as well as tested: returning the untrimmed text sent a pasted path
  // verbatim, and the server then reported "file not found:  /data/pr2.fa" with
  // the offending space invisible.
  const optional = (v: string) => (v.trim() === '' ? null : v.trim())

  return (
    <section style={{ flex: 1, minWidth: 280 }}>
      <h4 style={{ ...subheadingStyle, marginBottom: 8 }}>{title}</h4>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <label style={fieldLabelStyle}>
          Source URI
          <input
            value={format.uri}
            // The server only strips the uri for its emptiness test and writes it
            // to the YAML raw, so the trim happens here or not at all.
            onChange={e => set({ uri: e.target.value.trim() })}
            placeholder="https://..."
            style={{ ...pathInputStyle, borderColor: unresolved ? dangerColour : undefined }}
            disabled={disabled}
          />
          <span style={unresolved ? problemStyle : fieldHintStyle}>
            {unresolved
              ? 'Set a source URI or a local path: without one of them this format can never resolve.'
              : 'Downloaded into the cache directory. Required unless a local path is set.'}
          </span>
        </label>
        <label style={fieldLabelStyle}>
          Local path
          <input
            value={format.local ?? ''}
            onChange={e => set({ local: optional(e.target.value) })}
            placeholder="(none)"
            style={{ ...pathInputStyle, borderColor: unresolved ? dangerColour : undefined }}
            disabled={disabled}
          />
          <span style={fieldHintStyle}>
            A file already on this machine. Set it to skip the download. It need not exist yet.
          </span>
        </label>
        {remote && (
          <label style={fieldLabelStyle}>
            Remote path
            <input
              value={format.remote_path ?? ''}
              onChange={e => set({ remote_path: optional(e.target.value) })}
              placeholder="(none)"
              style={pathInputStyle}
              disabled={disabled}
            />
            <span style={fieldHintStyle}>A file already present on the remote taxonomy host.</span>
          </label>
        )}
      </div>
    </section>
  )
}

//## The ordered taxonomy levels
interface LevelsEditorProps {
  levels:   LevelRow[]
  onChange: (next: LevelRow[]) => void
  disabled: boolean
}

function LevelsEditor({ levels, onChange, disabled }: LevelsEditorProps) {
  const issues = nameIssues(levels.map(l => l.name))
  const add = () => onChange([...levels, { id: nextId(levels), name: '' }])

  return (
    <section>
      <div style={sectionHeadStyle}>
        <h4 style={subheadingStyle}>Taxonomy levels</h4>
        <button className="btn" onClick={add} disabled={disabled}>+ Level</button>
      </div>
      <p style={{ ...fieldHintStyle, marginBottom: 8 }}>
        Ordered from the broadest rank to the narrowest. The order maps onto the database's
        taxonomy columns, so it is not cosmetic.
      </p>
      {levels.length === 0 && <p style={emptyStyle}>None defined. A database needs at least one level.</p>}
      <div style={scrollListStyle}>
        {levels.map((l, i) => {
          const problem = issues[i] === 'blank'     ? 'name required'
                        : issues[i] === 'duplicate' ? 'duplicate level'
                        : null
          return (
            <div key={l.id} style={editorRowStyle}>
              <span style={ordinalStyle}>{i + 1}</span>
              <input
                value={l.name}
                onChange={e => onChange(patchAt(levels, i, { name: e.target.value }))}
                placeholder="Rank name"
                style={{ ...inputStyle, maxWidth: 220, borderColor: problem ? dangerColour : undefined }}
                disabled={disabled}
              />
              {problem && <span style={problemStyle}>{problem}</span>}
              <button
                className="btn"
                onClick={() => onChange(moveAt(levels, i, i - 1))}
                disabled={disabled || i === 0}
                title="Move up"
                style={{ marginLeft: 'auto' }}
              >
                Up
              </button>
              <button
                className="btn"
                onClick={() => onChange(moveAt(levels, i, i + 1))}
                disabled={disabled || i === levels.length - 1}
                title="Move down"
              >
                Down
              </button>
              <button className="btn" onClick={() => onChange(removeAt(levels, i))} disabled={disabled}>Remove</button>
            </div>
          )
        })}
      </div>
    </section>
  )
}

//## One correction
interface CorrectionEditorProps {
  correction: CorrectionRow
  levelNames: string[]
  onChange:   (next: CorrectionRow) => void
  onRemove:   () => void
  disabled:   boolean
}

function CorrectionEditor({ correction, levelNames, onChange, onRemove, disabled }: CorrectionEditorProps) {
  const set = (patch: Partial<CorrectionRow>) => onChange({ ...correction, ...patch })
  const addValue = () => set({ values: [...correction.values, { id: nextId(correction.values), from: '', to: '' }] })
  // The saved YAML holds the values as a mapping keyed by the source label, so two
  // rows sharing a source would collapse into one on save and a blank source has
  // nowhere to go. The server does not reject either, so the rows are marked here.
  const issues = nameIssues(correction.values.map(v => v.from))

  return (
    <div style={correctionStyle}>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 12, flexWrap: 'wrap' }}>
        <label style={{ ...fieldLabelStyle, flex: 1, minWidth: 170 }}>
          Source level
          <LevelSelect
            value={correction.source}
            levelNames={levelNames}
            onChange={v => set({ source: v })}
            disabled={disabled}
          />
        </label>
        <label style={{ ...fieldLabelStyle, flex: 1, minWidth: 170 }}>
          Target level
          <LevelSelect
            value={correction.target}
            levelNames={levelNames}
            onChange={v => set({ target: v })}
            disabled={disabled}
          />
        </label>
        <button className="btn" onClick={addValue} disabled={disabled}>+ Value</button>
        <button className="btn" onClick={onRemove} disabled={disabled}>Remove correction</button>
      </div>

      {correction.values.length === 0 && <p style={emptyStyle}>No values. This correction rewrites nothing.</p>}
      <div style={scrollListStyle}>
        {correction.values.map((v, i) => {
          const problem = issues[i] === 'blank'     ? 'source label required'
                        : issues[i] === 'duplicate' ? 'duplicate source label'
                        : null
          return (
            <div key={v.id} style={editorRowStyle}>
              <input
                value={v.from}
                onChange={e => onChange({ ...correction, values: patchAt(correction.values, i, { from: e.target.value }) })}
                placeholder="Label found at the source level"
                style={{ ...inputStyle, borderColor: problem ? dangerColour : undefined }}
                disabled={disabled}
              />
              <span style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)' }}>becomes</span>
              <input
                value={v.to}
                onChange={e => onChange({ ...correction, values: patchAt(correction.values, i, { to: e.target.value }) })}
                placeholder="Label written at the target level"
                style={inputStyle}
                disabled={disabled}
              />
              {problem && <span style={problemStyle}>{problem}</span>}
              <button
                className="btn"
                onClick={() => onChange({ ...correction, values: removeAt(correction.values, i) })}
                disabled={disabled}
              >
                Remove
              </button>
            </div>
          )
        })}
      </div>
    </div>
  )
}

//## A level chosen from the entry's own levels
// The server rejects a correction naming a level the database does not have, so
// the levels are offered rather than typed. A value that is no longer one of them,
// because the levels were edited after the correction was written, is kept as a
// marked option rather than being silently rewritten to another rank.
interface LevelSelectProps {
  value:      string
  levelNames: string[]
  onChange:   (next: string) => void
  disabled:   boolean
}

function LevelSelect({ value, levelNames, onChange, disabled }: LevelSelectProps) {
  const missing = value !== '' && !levelNames.includes(value)
  return (
    <select
      value={value}
      onChange={e => onChange(e.target.value)}
      style={{ ...inputStyle, borderColor: missing || value === '' ? dangerColour : undefined }}
      disabled={disabled}
    >
      {value === '' && <option value="">(choose a level)</option>}
      {missing && <option value={value}>{value} (not a level)</option>}
      {/* A level name is edited text, so it cannot key these options; the index
          can, an option carrying no state that a remount would lose. */}
      {levelNames.map((n, i) => <option key={i} value={n}>{n}</option>)}
    </select>
  )
}

//## Styles
const pathInputStyle: CSSProperties = { ...inputStyle, fontFamily: 'monospace', fontSize: '.8rem' }

const subheadingStyle: CSSProperties = {
  fontSize:   '.9rem',
  fontWeight: 700,
}

const sectionHeadStyle: CSSProperties = {
  display:        'flex',
  alignItems:     'center',
  justifyContent: 'space-between',
  gap:            10,
  marginBottom:   4,
}

// A long list scrolls within itself rather than dragging the whole page.
const scrollListStyle: CSSProperties = {
  display:       'flex',
  flexDirection: 'column',
  gap:           8,
  maxHeight:     260,
  overflowY:     'auto',
  paddingRight:  4,
}

const correctionStyle: CSSProperties = {
  display:       'flex',
  flexDirection: 'column',
  gap:           10,
  border:        '1px solid var(--color-border)',
  borderRadius:  6,
  padding:       12,
  background:    'var(--color-surface)',
}

const ordinalStyle: CSSProperties = {
  minWidth:  18,
  fontSize:  '.78rem',
  color:     'var(--color-muted-fg)',
  textAlign: 'right',
}

const emptyStyle: CSSProperties = {
  fontSize: '.82rem',
  color:    'var(--color-muted-fg)',
}

const problemStyle: CSSProperties = {
  fontWeight: 400,
  fontSize:   '.78rem',
  color:      dangerColour,
}

const metaStyle: CSSProperties = {
  fontSize: '.78rem',
  color:    'var(--color-muted-fg)',
}
