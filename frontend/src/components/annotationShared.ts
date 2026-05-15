// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import type { CSSProperties } from 'react'
import type { AnnotationMeta, AnnotationSource, ConfigSource } from '../api/types'
import { api } from '../api/client'

export type ContamStatus = 'unassigned' | 'yes' | 'no'


export const SOURCES: AnnotationSource[] = ['VSEARCH', 'DADA2']

/** Ranks ordered from finest to coarsest. */
export const RANK_ORDER = ['species', 'genus', 'family', 'order', 'class', 'division', 'supergroup'] as const

export const RANK_COL: Record<string, Record<AnnotationSource, string>> = {
  species:    { VSEARCH: 'Species',    DADA2: 'Species_dada2' },
  genus:      { VSEARCH: 'Genus',      DADA2: 'Genus_dada2' },
  family:     { VSEARCH: 'Family',     DADA2: 'Family_dada2' },
  order:      { VSEARCH: 'Order',      DADA2: 'Order_dada2' },
  class:      { VSEARCH: 'Class',      DADA2: 'Class_dada2' },
  division:   { VSEARCH: 'Division',   DADA2: 'Division_dada2' },
  supergroup: { VSEARCH: 'Supergroup', DADA2: 'Supergroup_dada2' },
}

/**
 * Find the finest rank that has a non-empty value in the row, starting from
 * `startRank` and walking coarser. Returns the rank name or null.
 */
export function findFinestRank(
  row: Record<string, unknown>,
  source: AnnotationSource,
  startRank: string = RANK_ORDER[0],
): string | null {
  const startIdx = RANK_ORDER.indexOf(startRank as typeof RANK_ORDER[number])
  const from = startIdx >= 0 ? startIdx : 0
  for (let i = from; i < RANK_ORDER.length; i++) {
    const rank = RANK_ORDER[i]
    const col = RANK_COL[rank]?.[source]
    if (col && row[col] != null && String(row[col]).trim() !== '') return rank
  }
  return null
}

export const SOURCE_COLORS: Record<ConfigSource, string> = {
  default: 'var(--color-muted-fg)',
  study:   '#e67700',
  group:   '#5c940d',
  run:     'var(--color-primary)',
}

export const BLAST_ASSIGNMENT_COLUMN = 'BLAST Assignment'

export const CONTAM_STYLE: Record<ContamStatus, CSSProperties> = {
  unassigned: { color: 'var(--color-muted-fg)' },
  yes:        { color: '#c92a2a', fontWeight: 600 },
  no:         { color: '#2b8a3e', fontWeight: 600 },
}


export const FUNCDB_FIELDS = [
  { key: 'Domain',                   label: 'Domain',                   required: false },
  { key: 'supergroup',               label: 'Supergroup',               required: false },
  { key: 'division',                 label: 'Division',                 required: false },
  { key: 'class',                    label: 'Class',                    required: false },
  { key: 'order',                    label: 'Order',                    required: false },
  { key: 'family',                   label: 'Family',                   required: false },
  { key: 'Genus',                    label: 'Genus',                    required: false },
  { key: 'Species',                  label: 'Species',                  required: false },
  { key: 'Assignment_level',         label: 'Assignment level',         required: false },
  { key: 'Function',                 label: 'Function',                 required: true },
  { key: 'Detailed_function',        label: 'Detailed function',        required: false },
  { key: 'Associated_organism',      label: 'Associated organism',      required: false },
  { key: 'Associated_material',      label: 'Associated material',      required: false },
  { key: 'Environment',              label: 'Environment',              required: false },
  { key: 'Potential_human_pathogen', label: 'Potential human pathogen', required: false },
  { key: 'Comment',                  label: 'Comment',                  required: false },
  { key: 'Reference',                label: 'Reference',                required: false },
]

export function prefillFromRow(row: Record<string, unknown>, source: AnnotationSource): Record<string, string> {
  const str = (v: unknown) => (v == null ? '' : String(v))
  const result: Record<string, string> = {}

  const taxMap: Array<[string, string]> = source === 'VSEARCH'
    ? [['Domain', 'Domain'], ['Supergroup', 'supergroup'], ['Division', 'division'], ['Class', 'class'],
       ['Order', 'order'], ['Family', 'family'], ['Genus', 'Genus'], ['Species', 'Species']]
    : [['Domain_dada2', 'Domain'], ['Supergroup_dada2', 'supergroup'], ['Division_dada2', 'division'], ['Class_dada2', 'class'],
       ['Order_dada2', 'order'], ['Family_dada2', 'family'], ['Genus_dada2', 'Genus'], ['Species_dada2', 'Species']]

  for (const [src, dest] of taxMap) {
    const v = str(row[src])
    if (v) result[dest] = v
  }

  const valueMap: Array<[string, string]> = [
    ['function', 'Function'],
    ['detailed_function', 'Detailed_function'],
    ['assoc_organism', 'Associated_organism'],
    ['assoc_material', 'Associated_material'],
    ['environment', 'Environment'],
    ['human_pathogen', 'Potential_human_pathogen'],
    ['comment', 'Comment'],
    ['reference', 'Reference'],
  ]

  for (const [src, dest] of valueMap) {
    const v = str(row[src])
    if (v) result[dest] = v
  }

  const rank = str(row.match_rank)
  if (rank && rank !== 'unmatched') result.Assignment_level = rank

  return result
}

export interface AnalysisOption {
  key: string
  table: string
  source: AnnotationSource
  label: string
}

/** Discover annotated tables available for a single run. */
export async function discoverAnnotationOptions(
  study: string, run: string, group?: string | null,
): Promise<AnalysisOption[]> {
  const listings = await Promise.all(
    SOURCES.map(source =>
      api.annotations.list(study, run, source, group).catch(() => [] as AnnotationMeta[]),
    ),
  )
  return listings
    .flat()
    .filter(meta => meta.status === 'fresh' || meta.status === 'stale')
    .map(meta => ({
      key: `${meta.source}:${meta.table}`,
      table: meta.table,
      source: meta.source,
      label: `${meta.table} (${meta.source})`,
    }))
    .sort((a, b) => a.table !== b.table ? a.table.localeCompare(b.table) : a.source.localeCompare(b.source))
}
