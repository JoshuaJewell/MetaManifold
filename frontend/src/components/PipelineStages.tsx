// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

import { useState, useEffect } from 'react'
import type { RunStages, StageStatus, ConfigMap, ConfigSource } from '../api/types'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from './Toast'
import { timeAgo } from '../utils/timeago'
import { SOURCE_COLORS } from './annotationShared'
import styles from './PipelineStages.module.css'

// cdhit config lives under dada2_denoise; merge_taxa is auto-chained and hidden
const VISIBLE_STAGES = ['cutadapt', 'dada2_denoise', 'dada2_classify', 'swarm', 'vsearch'] as const
type VisibleStage = typeof VISIBLE_STAGES[number]

// Config sections include pipeline stages plus non-stage sections like study_design
export type ConfigSection = VisibleStage | 'study_design' | 'annotation' | 'analysis' | 'global'

export const STAGE_LABELS: Record<ConfigSection, string> = {
  global:         'Global',
  study_design:   'Study Design',
  cutadapt:       'Primer Trimming',
  dada2_denoise:  'DADA2 Denoising',
  dada2_classify: 'Taxonomy Assignment (DADA2)',
  swarm:          'OTU Clustering (SWARM)',
  vsearch:        'Taxonomy Assignment (VSEARCH)',
  annotation:     'Annotation',
  analysis:       'Analysis',
}

export const STAGE_CONFIG_PREFIXES: Record<ConfigSection, string[]> = {
  global:         ['your_name'],
  study_design:   ['seed', 'subsample_n', 'pool_children'],
  cutadapt:       ['cutadapt.'],
  dada2_denoise:  ['dada2.file_patterns.', 'dada2.filter_trim.', 'dada2.dada.', 'dada2.merge.', 'dada2.asv.', 'cdhit.'],
  dada2_classify: ['dada2.taxonomy.', 'dada2.output.'],
  swarm:          ['swarm.'],
  vsearch:        ['vsearch.'],
  annotation:     ['annotation.max_rank', 'annotation.contamination.'],
  analysis:       ['analysis.include_contamination', 'analysis.alpha.', 'analysis.nmds.', 'analysis.taxa_bar.'],
}

const STAGE_ORDER = [...VISIBLE_STAGES]

export const CONFIG_DESCRIPTIONS: Record<string, string> = {
  'your_name':                      'Your name or identifier - pre-fills the "Modified by" field when adding FuncDB entries.',
  'pool_children':                  'Pool FASTQ files from child directories into a single run. Each child directory becomes a sub-group identified by a prefix.',
  'seed':                           'Global random seed used by stages that require randomness.',
  'subsample_n':                    'Number of samples to randomly select per run for quick config iteration (0 = all). 3 is recommended for testing DADA2 parameters.',
  'cutadapt.primer_pairs':        'Primer pair names to apply. Must match keys in config/primers.yml.',
  'cutadapt.min_length':          'Discard reads shorter than this after trimming (-m).',
  'cutadapt.discard_untrimmed':   'Drop reads where no adapter was found (--discard-untrimmed).',
  'cutadapt.cores':               'Parallel cores; 0 = auto-detect (-j).',
  'cutadapt.quality_cutoff':      "3' quality trimming cutoff; null to disable (-q).",
  'cutadapt.error_rate':          'Max adapter mismatch rate; null = cutadapt default (-e).',
  'cutadapt.overlap':             'Min adapter overlap length; null = cutadapt default (-O).',
  'cutadapt.r1_suffix':           'Filename suffix identifying R1 (forward) reads, e.g. "_R1" or "_1".',
  'cutadapt.r2_suffix':           'Filename suffix identifying R2 (reverse) reads, e.g. "_R2" or "_2".',
  'cutadapt.optional_args':       'Additional flags passed verbatim to cutadapt.',
  'dada2.file_patterns.mode':     'Read mode: paired, forward, or reverse.',
  'dada2.filter_trim.trunc_q':    'Truncate reads at the first base with quality <= this value.',
  'dada2.filter_trim.trunc_len':  '[forward, reverse] truncation lengths; first value used for single-end.',
  'dada2.filter_trim.max_ee':     '[forward, reverse] max expected errors. Reads exceeding this are discarded.',
  'dada2.filter_trim.min_len':    'Discard reads shorter than this after truncation.',
  'dada2.filter_trim.max_n':      'Max number of ambiguous (N) bases allowed; 0 = none.',
  'dada2.filter_trim.match_ids':  'Require forward/reverse read IDs to match.',
  'dada2.filter_trim.rm_phix':    'Remove reads matching the PhiX genome.',
  'dada2.dada.nbases':            'Number of bases used for error model learning.',
  'dada2.dada.max_consist':       'Max iterations for error model convergence.',
  'dada2.dada.pool_method':       'Sample pooling: none, pseudo (recommended), or true (memory-intensive).',
  'dada2.merge.min_overlap':      'Minimum overlap (bp) required to merge forward/reverse reads.',
  'dada2.merge.max_mismatch':     'Max mismatches allowed in the overlap region.',
  'dada2.merge.trim_overhang':    'Trim overhanging bases beyond the start of the opposite read.',
  'dada2.asv.band_size_min':      'Min ASV length to keep; null to skip length filtering.',
  'dada2.asv.band_size_max':      'Max ASV length to keep.',
  'dada2.asv.denovo_method':      'Chimera removal method: consensus or pooled.',
  'dada2.taxonomy.enabled':       'Set to false to skip DADA2 taxonomy assignment.',
  'dada2.taxonomy.database':      'Reference database key (from config/databases.yml).',
  'dada2.taxonomy.multithread':   'Threads for assignTaxonomy; higher values increase memory use significantly.',
  'dada2.taxonomy.min_boot':      'Minimum bootstrap confidence for taxonomy assignment.',
  'dada2.taxonomy.remote.host':         'SSH user@hostname for remote execution; null = run locally.',
  'dada2.taxonomy.remote.identity_file':'Path to SSH private key; null = password auth.',
  'dada2.taxonomy.remote.rscript':      'Path to Rscript on the remote server.',
  'dada2.taxonomy.remote.staging_dir':  'Absolute path on the remote server for staging files.',
  'dada2.output.seq_table_prefix':'Filename prefix for the sequence table output.',
  'dada2.output.fasta_prefix':    'Filename prefix for the ASV FASTA output.',
  'dada2.output.taxa_prefix':     'Filename prefix for the taxonomy table output.',
  'dada2.verbose':                'Print verbose progress messages during DADA2 execution.',
  'vsearch.enabled':              'Set to false to skip VSEARCH taxonomy assignment entirely.',
  'vsearch.identity':             'Minimum sequence identity threshold (--id).',
  'vsearch.query_cov':            'Minimum fraction of query sequence covered (--query_cov).',
  'vsearch.maxaccepts':           'Stop after this many hits per query; null = vsearch default (--maxaccepts).',
  'vsearch.maxrejects':           'Max rejected candidates per query; null = vsearch default (--maxrejects).',
  'vsearch.strand':               '"plus" or "both"; null = vsearch default (--strand).',
  'vsearch.optional_args':        'Additional flags passed verbatim to vsearch.',
  'cdhit.enabled':                'Run CD-HIT ASV dereplication before OTU clustering.',
  'cdhit.identity':               'Sequence identity threshold (-c); use 1.0 to deduplicate only.',
  'cdhit.threads':                'Worker threads; 0 = all available (-T).',
  'cdhit.optional_args':          'Additional flags passed verbatim to cd-hit-est.',
  'swarm.enabled':                'Set to false to skip OTU clustering entirely.',
  'swarm.differences':            'Max differences between sequences in the same cluster (-d).',
  'swarm.threads':                'Worker threads; 0 = all available (-t).',
  'swarm.chimera_check':          'Run vsearch --uchime_denovo before clustering.',
  'swarm.min_abundance':          'Discard singleton dereps before clustering (--minsize).',
  'swarm.fastq_minovlen':         'Min overlap for paired-end merging (--fastq_minovlen).',
  'swarm.identity':               'Threshold for mapping reads back to OTU seeds (--id).',
  'swarm.optional_args':          'Additional flags passed verbatim to swarm.',
  'analysis.taxa_bar.top_n':      'Collapse taxa below this rank count to "Other".',
  'analysis.taxa_bar.rank':       'Taxonomic rank for bar plots; null = lowest assigned rank.',
  'analysis.taxa_bar.ranks':      'Rank levels to plot; null = auto (last 3 levels).',
  'analysis.taxa_bar.report_ranks':'Ranks to include in the report; null = auto (last 3 levels).',
  'analysis.alpha.metrics':       'Alpha diversity metrics to compute.',
  'analysis.include_contamination': 'Include rows marked as contamination in analysis outputs. When false, only annotation rows tagged "no" in Contamination are used.',
  'analysis.alpha.show_points':   'Show individual samples overlaid on alpha comparison boxplots.',
  'analysis.alpha.annotate_significance': 'Annotate alpha comparison panels with Kruskal-Wallis significance.',
  'analysis.alpha.pairwise_brackets': 'Run BH-adjusted pairwise Wilcoxon rank-sum tests between every group pair and draw brackets, including n.s. results.',
  'analysis.alpha.paired_samples': 'Use paired-sample tests by matching sample IDs across groups. Uses paired Wilcoxon for 2 groups and Friedman for 3+ groups.',
  'analysis.alpha.significance_test': 'Overall significance test used for alpha comparison annotations.',
  'analysis.nmds.distance':       'Distance metric for NMDS ordination.',
  'analysis.nmds.max_stress':     'Warn if NMDS stress exceeds this value.',
  'annotation.max_rank':          'Finest taxonomy rank used during FuncDB annotation. Finer ranks are ignored and removed from generated annotation tables.',
  'annotation.contamination.min_consensus_rank':  'Only apply contamination filter when VSEARCH/DADA2 consensus is at this rank or finer. Empty = no rank gate.',
  'annotation.contamination.min_consensus_score': 'Only apply contamination filter when consensus_score is at or above this value (0-1). 0 = no score gate.',
  'annotation.contamination.blacklist.function':            'One entry per line. Rows whose function column matches an entry are marked as contamination.',
  'annotation.contamination.blacklist.detailed_function':   'One entry per line. Rows whose detailed_function column matches an entry are marked as contamination.',
  'annotation.contamination.blacklist.associated_organism': 'One entry per line. Rows whose assoc_organism column matches are marked as contamination.',
  'annotation.contamination.blacklist.associated_material': 'One entry per line. Rows whose assoc_material column matches are marked as contamination.',
  'annotation.contamination.blacklist.environment':         'One entry per line. Rows whose environment column matches are marked as contamination.',
  'annotation.contamination.whitelist.function':            'One entry per line. Rows whose function column matches an entry are marked as non-contamination.',
  'annotation.contamination.whitelist.detailed_function':   'One entry per line. Rows whose detailed_function column matches an entry are marked as non-contamination.',
  'annotation.contamination.whitelist.associated_organism': 'One entry per line. Rows whose assoc_organism column matches are marked as non-contamination.',
  'annotation.contamination.whitelist.associated_material': 'One entry per line. Rows whose assoc_material column matches are marked as non-contamination.',
  'annotation.contamination.whitelist.environment':         'One entry per line. Rows whose environment column matches are marked as non-contamination.',
}

export type ConfigType =
  | { kind: 'boolean' }
  | { kind: 'int'; nullable?: boolean }
  | { kind: 'float'; nullable?: boolean; min?: number; max?: number; step?: number }
  | { kind: 'enum'; options: string[] }
  | { kind: 'multiselect'; optionsFrom: string }
  | { kind: 'string_list' }

/** Explicit type hints for config keys that aren't plain strings or arrays. */
export const CONFIG_TYPES: Record<string, ConfigType> = {
  'pool_children':                  { kind: 'boolean' },
  'seed':                           { kind: 'int' },
  'subsample_n':                    { kind: 'int' },
  'cutadapt.primer_pairs':        { kind: 'multiselect', optionsFrom: 'primers' },
  'cutadapt.min_length':          { kind: 'int' },
  'cutadapt.discard_untrimmed':   { kind: 'boolean' },
  'cutadapt.cores':               { kind: 'int' },
  'cutadapt.quality_cutoff':      { kind: 'int', nullable: true },
  'cutadapt.error_rate':          { kind: 'float', nullable: true, min: 0, max: 1, step: 0.01 },
  'cutadapt.overlap':             { kind: 'int', nullable: true },
  'dada2.file_patterns.mode':     { kind: 'enum', options: ['paired', 'forward', 'reverse'] },
  'dada2.filter_trim.trunc_q':    { kind: 'int' },
  'dada2.filter_trim.min_len':    { kind: 'int' },
  'dada2.filter_trim.max_n':      { kind: 'int' },
  'dada2.filter_trim.match_ids':  { kind: 'boolean' },
  'dada2.filter_trim.rm_phix':    { kind: 'boolean' },
  'dada2.dada.nbases':            { kind: 'int' },
  'dada2.dada.max_consist':       { kind: 'int' },
  'dada2.dada.pool_method':       { kind: 'enum', options: ['none', 'pseudo', 'true'] },
  'dada2.merge.min_overlap':      { kind: 'int' },
  'dada2.merge.max_mismatch':     { kind: 'int' },
  'dada2.merge.trim_overhang':    { kind: 'boolean' },
  'dada2.asv.band_size_min':      { kind: 'int', nullable: true },
  'dada2.asv.band_size_max':      { kind: 'int' },
  'dada2.asv.denovo_method':      { kind: 'enum', options: ['consensus', 'pooled'] },
  'dada2.taxonomy.enabled':       { kind: 'boolean' },
  'dada2.taxonomy.multithread':   { kind: 'int' },
  'dada2.taxonomy.min_boot':      { kind: 'int' },
  'dada2.verbose':                { kind: 'boolean' },
  'vsearch.identity':             { kind: 'float', min: 0, max: 1, step: 0.01 },
  'vsearch.query_cov':            { kind: 'float', min: 0, max: 1, step: 0.01 },
  'vsearch.maxaccepts':           { kind: 'int', nullable: true },
  'vsearch.maxrejects':           { kind: 'int', nullable: true },
  'vsearch.strand':               { kind: 'enum', options: ['plus', 'both'] },
  'vsearch.enabled':              { kind: 'boolean' },
  'cdhit.enabled':                { kind: 'boolean' },
  'cdhit.identity':               { kind: 'float', min: 0, max: 1, step: 0.01 },
  'cdhit.threads':                { kind: 'int' },
  'swarm.enabled':                { kind: 'boolean' },
  'swarm.differences':            { kind: 'int' },
  'swarm.threads':                { kind: 'int' },
  'swarm.chimera_check':          { kind: 'boolean' },
  'swarm.min_abundance':          { kind: 'int' },
  'swarm.fastq_minovlen':         { kind: 'int' },
  'swarm.identity':               { kind: 'float', min: 0, max: 1, step: 0.01 },
  'analysis.taxa_bar.top_n':      { kind: 'int' },
  'annotation.max_rank':          { kind: 'enum', options: ['species', 'genus', 'family', 'order', 'class', 'division', 'supergroup'] },
  'annotation.contamination.min_consensus_rank':  { kind: 'enum', options: ['', 'species', 'genus', 'family', 'order', 'class', 'division', 'supergroup'] },
  'annotation.contamination.min_consensus_score': { kind: 'float', min: 0, max: 1, step: 0.01, nullable: true },
  'annotation.contamination.blacklist.function':            { kind: 'string_list' },
  'annotation.contamination.blacklist.detailed_function':   { kind: 'string_list' },
  'annotation.contamination.blacklist.associated_organism': { kind: 'string_list' },
  'annotation.contamination.blacklist.associated_material': { kind: 'string_list' },
  'annotation.contamination.blacklist.environment':         { kind: 'string_list' },
  'annotation.contamination.whitelist.function':            { kind: 'string_list' },
  'annotation.contamination.whitelist.detailed_function':   { kind: 'string_list' },
  'annotation.contamination.whitelist.associated_organism': { kind: 'string_list' },
  'annotation.contamination.whitelist.associated_material': { kind: 'string_list' },
  'annotation.contamination.whitelist.environment':         { kind: 'string_list' },
  'analysis.include_contamination': { kind: 'boolean' },
  'analysis.alpha.show_points':   { kind: 'boolean' },
  'analysis.alpha.annotate_significance': { kind: 'boolean' },
  'analysis.alpha.pairwise_brackets': { kind: 'boolean' },
  'analysis.alpha.paired_samples': { kind: 'boolean' },
  'analysis.alpha.significance_test': { kind: 'enum', options: ['kruskal_wallis'] },
  'analysis.nmds.max_stress':     { kind: 'float', min: 0, max: 1, step: 0.01 },
  'analysis.nmds.distance':       { kind: 'enum', options: ['bray_curtis'] },
}


interface Props {
  stages:   RunStages
  onRun?:   (stage: string) => void
  disabled?: boolean
  configMap?: ConfigMap | null
  study?:    string
  run?:      string
  group?:    string
  onConfigChanged?: () => void
}

function StatusDot({ status }: { status: StageStatus }) {
  return <span className={`${styles.dot} ${styles[status]}`} title={status} />
}

export function PipelineStages({ stages, onRun, disabled, configMap, study, run, group, onConfigChanged }: Props) {
  const [expanded, setExpanded] = useState<string | null>(null)
  const [pending, setPending]   = useState<Set<string>>(new Set())

  useEffect(() => {
    setPending(prev => {
      if (prev.size === 0) return prev
      const next = new Set(prev)
      for (const key of prev) {
        const status = stages?.[key as keyof RunStages]?.status
        if (status === 'running' || status === 'complete' || status === 'stale' || status === 'not_started')
          next.delete(key)
      }
      return next.size === prev.size ? prev : next
    })
  }, [stages])

  return (
    <div className={styles.grid}>
      {STAGE_ORDER.map(key => {
        const info = stages?.[key]
        const status   = info?.status ?? 'not_started'
        const last_run = info?.last_run ?? null
        const isExpanded = expanded === key
        const hasConfig = configMap && STAGE_CONFIG_PREFIXES[key].some(
          prefix => Object.keys(configMap).some(k => k.startsWith(prefix))
        )
        // Count how many config keys are overridden at run level for this stage
        const runOverrides = configMap ? STAGE_CONFIG_PREFIXES[key].reduce((n, prefix) =>
          n + Object.entries(configMap).filter(([k, { source }]) => k.startsWith(prefix) && source === 'run').length, 0) : 0
        return (
          <div key={key}>
            <div className={`${styles.row} ${styles[status]}`}>
              <StatusDot status={status} />
              <span
                className={styles.label}
                style={{ cursor: hasConfig ? 'pointer' : 'default' }}
                onClick={() => hasConfig && setExpanded(isExpanded ? null : key)}
              >
                {hasConfig && <span style={{ fontSize: '.8rem', marginRight: 6, opacity: .65 }}>{isExpanded ? 'v' : '>'}</span>}
                {STAGE_LABELS[key]}
                {runOverrides > 0 && (
                  <span style={{ marginLeft: 6, fontSize: '.68rem', fontWeight: 600, color: 'var(--color-primary)', verticalAlign: 'middle' }}
                    title={`${runOverrides} run-level override${runOverrides > 1 ? 's' : ''}`}>
                    {runOverrides} override{runOverrides > 1 ? 's' : ''}
                  </span>
                )}
              </span>
              <span className={styles.ts} title={last_run ? new Date(last_run).toLocaleString() : ''}>{last_run ? timeAgo(last_run) : '-'}</span>
              {onRun && status !== 'disabled' && (
                <button
                  className={styles.run}
                  disabled={disabled || status === 'running' || pending.has(key)}
                  onClick={() => { setPending(prev => new Set(prev).add(key)); onRun(key) }}
                >
                  {status === 'running' || pending.has(key) ? '...' : 'Run'}
                </button>
              )}
            </div>
            {isExpanded && configMap && study && run && onConfigChanged && (
              <StageConfig
                configMap={configMap}
                prefixes={STAGE_CONFIG_PREFIXES[key]}
                study={study}
                run={run}
                group={group}
                onConfigChanged={onConfigChanged}
              />
            )}
          </div>
        )
      })}
    </div>
  )
}

export function StageConfig({ configMap, prefixes, study, run, group, onConfigChanged, patchFn, deleteFn, sourceLevel, overrides }: {
  configMap: ConfigMap
  prefixes: string[]
  study: string
  run: string
  group?: string
  onConfigChanged: () => void
  patchFn?: (study: string, run: string, body: Record<string, unknown>, group?: string) => Promise<ConfigMap>
  deleteFn?: (study: string, run: string, key: string, group?: string) => Promise<ConfigMap>
  sourceLevel?: ConfigSource
  overrides?: Record<string, string[]> | null
}) {
  // Group entries by section prefix for nice headers
  const sections: { label: string | null; entries: { dottedKey: string; leafKey: string; value: unknown; source: ConfigSource }[] }[] = []

  for (const prefix of prefixes) {
    const isSectionPrefix = prefix.endsWith('.')
    const sectionEntries = Object.entries(configMap)
      .filter(([k]) => isSectionPrefix ? k.startsWith(prefix) : k === prefix)
      .map(([k, { value, source }]) => ({
        dottedKey: k,
        leafKey: isSectionPrefix ? k.slice(prefix.length) : k,
        value,
        source,
      }))
      .sort((a, b) => a.leafKey.localeCompare(b.leafKey))
    if (sectionEntries.length > 0) {
      const label = isSectionPrefix
        ? (prefix.replace(/\.$/, '').split('.').pop() ?? prefix)
            .replace(/_/g, ' ')
            .replace(/\b\w/g, c => c.toUpperCase())
        : null
      sections.push({ label, entries: sectionEntries })
    }
  }

  if (sections.length === 0) return null

  return (
    <div className={styles.configPanel}>
      {sections.map(section => (
        <div key={section.label ?? section.entries.map(e => e.dottedKey).join('|')}>
          {section.label && (
            <div style={{ fontWeight: 600, fontSize: '.78rem', marginBottom: 2, marginTop: 4 }}>{section.label}</div>
          )}
          {section.entries.map(e => (
            <StageConfigField
              key={e.dottedKey}
              dottedKey={e.dottedKey}
              leafKey={e.leafKey}
              value={e.value}
              source={e.source}
              study={study}
              run={run}
              group={group}
              onChanged={onConfigChanged}
              patchFn={patchFn}
              deleteFn={deleteFn}
              sourceLevel={sourceLevel}
              overrides={overrides?.[e.dottedKey]}
            />
          ))}
        </div>
      ))}
    </div>
  )
}

function StageConfigField({ dottedKey, leafKey, value, source, study, run, group, onChanged, patchFn, deleteFn, sourceLevel = 'run', overrides }: {
  dottedKey: string
  leafKey: string
  value: unknown
  source: ConfigSource
  study: string
  run: string
  group?: string
  onChanged: () => void
  patchFn?: (study: string, run: string, body: Record<string, unknown>, group?: string) => Promise<ConfigMap>
  deleteFn?: (study: string, run: string, key: string, group?: string) => Promise<ConfigMap>
  sourceLevel?: ConfigSource
  overrides?: string[]
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState('')
  const [saving, setSaving] = useState(false)
  const toast = useToast()

  const tooltip = CONFIG_DESCRIPTIONS[dottedKey]
  const typeHint = CONFIG_TYPES[dottedKey]

  const displayValue = Array.isArray(value) ? JSON.stringify(value)
    : value === null || value === undefined ? 'null'
    : typeof value === 'boolean' ? (value ? 'true' : 'false')
    : typeof value === 'object' ? JSON.stringify(value)
    : String(value)

  const startEdit = () => {
    // Booleans, enums, and multiselects use inline controls, no draft needed
    if (typeHint?.kind === 'boolean' || typeHint?.kind === 'enum' || typeHint?.kind === 'multiselect') return
    if (typeHint?.kind === 'string_list') {
      const items = Array.isArray(value) ? (value as string[]) : []
      setDraft(items.join('\n'))
    } else {
      setDraft(typeof value === 'string' ? value : JSON.stringify(value))
    }
    setEditing(true)
  }

  const saveValue = async (newValue: unknown) => {
    setSaving(true)
    try {
      const patch = patchFn ?? api.config.patchRun
      await patch(study, run, { [dottedKey]: newValue }, group)
      setEditing(false)
      onChanged()
    } catch (err) {
      toast.error('Failed to save: ' + (errorMessage(err)))
    } finally {
      setSaving(false)
    }
  }

  const save = async () => {
    let parsed: unknown
    if (typeHint?.kind === 'string_list') {
      parsed = draft.split('\n').map(s => s.trim()).filter(s => s.length > 0)
    } else {
      try { parsed = JSON.parse(draft) } catch { parsed = draft }
    }
    await saveValue(parsed)
  }

  const remove = async () => {
    setSaving(true)
    try {
      const del = deleteFn ?? api.config.deleteRun
      await del(study, run, dottedKey, group)
      setEditing(false)
      onChanged()
    } catch (err) {
      toast.error('Failed to remove: ' + (errorMessage(err)))
    } finally {
      setSaving(false)
    }
  }

  const labelEl = (
    <div style={{ minWidth: 120, fontSize: '.78rem' }}>
      {(leafKey || dottedKey).replace(/_/g, ' ')}
      {overrides && overrides.length > 0 && (
        <div style={{ fontSize: '.68rem', color: '#e67700', lineHeight: 1.2 }}
          title={overrides.join(', ')}>
          {overrides.length} override{overrides.length > 1 ? 's' : ''}
        </div>
      )}
    </div>
  )
  const sourceEl = <span style={{ fontSize: '.68rem', fontWeight: 600, color: SOURCE_COLORS[source], textTransform: 'uppercase', whiteSpace: 'nowrap' }}>{source}</span>
  const removeBtn = source === sourceLevel && (
    <button className="btn" style={{ padding: '0 4px', fontSize: '.68rem', lineHeight: 1 }} title={`Remove ${sourceLevel} override`}
      onClick={e => { e.stopPropagation(); remove() }}>&times;</button>
  )

  if (typeHint?.kind === 'boolean') {
    return (
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '2px 0 2px 8px' }} title={tooltip}>
        {labelEl}
        <input type="checkbox" checked={!!value} disabled={saving}
          onChange={e => saveValue(e.target.checked)}
          style={{ accentColor: 'var(--color-primary)' }} />
        <span style={{ fontFamily: 'monospace', fontSize: '.78rem', flex: 1 }}>{value ? 'true' : 'false'}</span>
        {sourceEl}{removeBtn}
      </div>
    )
  }

  if (typeHint?.kind === 'enum') {
    const nullable = value === null || value === undefined
    return (
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '2px 0 2px 8px' }} title={tooltip}>
        {labelEl}
        <select
          value={nullable ? '' : String(value)}
          disabled={saving}
          onChange={e => saveValue(e.target.value || null)}
          style={{ fontFamily: 'monospace', fontSize: '.78rem', padding: '1px 4px', border: '1px solid var(--color-border)', borderRadius: 3, background: 'var(--color-bg)' }}
        >
          {nullable && <option value="">null</option>}
          {typeHint.options.map(o => <option key={o} value={o}>{o}</option>)}
        </select>
        <div style={{ flex: 1 }} />
        {sourceEl}{removeBtn}
      </div>
    )
  }

  if (typeHint?.kind === 'multiselect') {
    return <MultiSelectField
      value={value} tooltip={tooltip} optionsFrom={typeHint.optionsFrom}
      saving={saving} saveValue={saveValue}
      labelEl={labelEl} sourceEl={sourceEl} removeBtn={removeBtn}
    />
  }

  if (typeHint?.kind === 'string_list') {
    const items = Array.isArray(value) ? (value as string[]) : []
    if (editing) {
      return (
        <div style={{ display: 'flex', gap: 6, alignItems: 'flex-start', padding: '2px 0 2px 8px' }} title={tooltip}>
          {labelEl}
          <textarea
            style={{ flex: 1, fontFamily: 'monospace', fontSize: '.78rem', padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 3, resize: 'vertical', minHeight: 60, background: 'var(--color-bg)', color: 'inherit' }}
            value={draft}
            onChange={e => setDraft(e.target.value)}
            autoFocus disabled={saving}
            placeholder="one entry per line"
          />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <button className="btn" style={{ padding: '1px 6px', fontSize: '.72rem' }} onClick={save} disabled={saving}>Save</button>
            <button className="btn" style={{ padding: '1px 6px', fontSize: '.72rem' }} onClick={() => setEditing(false)} disabled={saving}>Cancel</button>
          </div>
        </div>
      )
    }
    const preview = items.length === 0 ? '(empty)'
      : items.length <= 3 ? items.join(', ')
      : `${items.slice(0, 3).join(', ')} ... (${items.length})`
    return (
      <div
        style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '2px 0 2px 8px', cursor: 'pointer' }}
        onClick={startEdit}
        title={tooltip ?? 'Click to edit'}
      >
        {labelEl}
        <div style={{ fontFamily: 'monospace', fontSize: '.78rem', flex: 1, color: items.length === 0 ? 'var(--color-muted-fg)' : undefined }}>{preview}</div>
        {sourceEl}{removeBtn}
      </div>
    )
  }

  if (editing) {
    const isNumeric = typeHint?.kind === 'int' || typeHint?.kind === 'float'
    const nullable = isNumeric && typeHint.nullable
    return (
      <div style={{ display: 'flex', gap: 6, alignItems: 'center', padding: '2px 0 2px 8px' }} title={tooltip}>
        {labelEl}
        {isNumeric ? (
          <input
            type="number"
            style={{ width: 100, fontFamily: 'monospace', fontSize: '.78rem', padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 3 }}
            value={draft}
            step={typeHint.kind === 'float' ? (typeHint.step ?? 0.01) : 1}
            min={typeHint.kind === 'float' ? typeHint.min : undefined}
            max={typeHint.kind === 'float' ? typeHint.max : undefined}
            onChange={e => setDraft(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') save(); if (e.key === 'Escape') setEditing(false) }}
            autoFocus disabled={saving}
          />
        ) : (
          <input
            style={{ flex: 1, fontFamily: 'monospace', fontSize: '.78rem', padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 3 }}
            value={draft}
            onChange={e => setDraft(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') save(); if (e.key === 'Escape') setEditing(false) }}
            autoFocus disabled={saving}
          />
        )}
        {nullable && (
          <button className="btn" style={{ padding: '1px 6px', fontSize: '.72rem' }}
            onClick={() => saveValue(null)} disabled={saving}>null</button>
        )}
        <button className="btn" style={{ padding: '1px 6px', fontSize: '.72rem' }} onClick={save} disabled={saving}>Save</button>
        <button className="btn" style={{ padding: '1px 6px', fontSize: '.72rem' }} onClick={() => setEditing(false)} disabled={saving}>Cancel</button>
      </div>
    )
  }

  return (
    <div
      style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '2px 0 2px 8px', cursor: 'pointer' }}
      onClick={startEdit}
      title={tooltip ?? 'Click to edit'}
    >
      {labelEl}
      <div style={{ fontFamily: 'monospace', fontSize: '.78rem', flex: 1 }}>{displayValue}</div>
      {sourceEl}{removeBtn}
    </div>
  )
}

const MULTISELECT_FETCHERS: Record<string, () => Promise<string[]>> = {
  primers: () => api.primers.list(),
}

function MultiSelectField({ value, tooltip, optionsFrom, saving, saveValue,
  labelEl, sourceEl, removeBtn,
}: {
  value: unknown
  tooltip?: string; optionsFrom: string; saving: boolean
  saveValue: (v: unknown) => Promise<void>
  labelEl: React.ReactNode; sourceEl: React.ReactNode; removeBtn: React.ReactNode
}) {
  const [options, setOptions] = useState<string[] | null>(null)
  const [open, setOpen] = useState(false)
  const selected = Array.isArray(value) ? value.map(String) : []

  useEffect(() => {
    const fetcher = MULTISELECT_FETCHERS[optionsFrom]
    if (fetcher) fetcher().then(setOptions).catch(() => setOptions([]))
  }, [optionsFrom])

  const toggle = (opt: string) => {
    const next = selected.includes(opt)
      ? selected.filter(s => s !== opt)
      : [...selected, opt]
    saveValue(next)
  }

  return (
    <div style={{ padding: '2px 0 2px 8px' }} title={tooltip}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        {labelEl}
        <div
          style={{ fontFamily: 'monospace', fontSize: '.78rem', flex: 1, cursor: 'pointer', padding: '1px 4px', border: '1px solid var(--color-border)', borderRadius: 3, minHeight: 22, display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center' }}
          onClick={() => setOpen(!open)}
        >
          {selected.length > 0
            ? selected.map(s => (
                <span key={s} style={{ background: 'var(--color-primary)', color: '#fff', borderRadius: 3, padding: '0 5px', fontSize: '.72rem', lineHeight: '18px' }}>
                  {s}
                </span>
              ))
            : <span style={{ color: 'var(--color-muted-fg)' }}>none</span>}
          <span style={{ marginLeft: 'auto', fontSize: '.68rem', opacity: .5 }}>{open ? 'Hide' : 'Show'}</span>
        </div>
        {sourceEl}{removeBtn}
      </div>
      {open && options && (
        <div style={{ marginLeft: 128, marginTop: 4, border: '1px solid var(--color-border)', borderRadius: 4, padding: 6, maxWidth: 300 }}>
          {options.map(opt => (
            <label key={opt} style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: '.78rem', cursor: 'pointer', padding: '2px 0' }}>
              <input type="checkbox" checked={selected.includes(opt)} disabled={saving}
                onChange={() => toggle(opt)} style={{ accentColor: 'var(--color-primary)' }} />
              {opt}
            </label>
          ))}
          {options.length === 0 && <div style={{ fontSize: '.75rem', color: 'var(--color-muted-fg)' }}>No options available</div>}
        </div>
      )}
    </div>
  )
}
