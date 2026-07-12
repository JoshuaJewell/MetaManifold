export interface StudySummary {
  name:             string
  run_count:        number
  group_count:      number
  active_job_count: number
}

export interface Study extends StudySummary {
  runs:   string[]
  groups: string[]
}

export type StageStatus = 'not_started' | 'running' | 'complete' | 'stale' | 'disabled'

export interface StageInfo {
  status:      StageStatus
  last_run:    string | null
  stale_keys?: string[]
}

export interface RunStages {
  fastqc:         StageInfo
  cutadapt:       StageInfo
  dada2_denoise:  StageInfo
  dada2_classify: StageInfo
  cdhit:          StageInfo
  swarm:          StageInfo
  vsearch:        StageInfo
  merge_taxa:     StageInfo
}

export interface Run {
  name:         string
  study:        string
  sample_count: number
  samples:      string[]
  stages:       RunStages
  pooled:       boolean
  subgroups:    string[]
}

export type JobStatus = 'queued' | 'running' | 'complete' | 'failed' | 'cancelled'
export type JobType   = 'pipeline' | 'stage' | 'db_download'

export interface Job {
  id:          string
  type:        JobType
  study:       string | null
  run:         string | null
  stage:       string | null
  status:      JobStatus
  created_at:  string
  finished_at: string | null
  message:     string | null
}

export interface PlotMeta {
  id:    string
  label: string
  stage: string
}

export interface TableMeta {
  id:           string
  label:        string
  rows:         number
  total_reads:  number
  n_samples:    number
}

export interface ColFilter {
  text?:     string
  include?:  string[]
  exclude?:  string[]
  min?:      number
  max?:      number
}

export interface TableQuery {
  page:        number
  perPage:     number
  filter?:     string
  sortBy?:     string
  sortDir?:    'asc' | 'desc'
  colFilters?: Record<string, ColFilter>
}

export interface DistinctText {
  column: string
  type:   'text'
  values: string[]
  count:  number
}

export interface DistinctNumeric {
  column: string
  type:   'numeric'
  min:    number
  max:    number
  count:  number
  sum:    number
  mean:   number
  median: number
  q1:     number
  q3:     number
}

export type DistinctInfo = DistinctText | DistinctNumeric

export interface TablePage {
  total:                  number
  total_unfiltered:       number
  total_reads:            number
  total_reads_unfiltered: number
  page:                   number
  per_page:               number
  columns:                string[]
  sample_count_columns:   string[]
  rows:                   Record<string, unknown>[]
}

export type ConfigSource = 'default' | 'study' | 'group' | 'run'

export type ConfigMap = Record<string, { value: unknown; source: ConfigSource }>

export interface DatabaseEntry {
  key:              string
  label:            string
  dada2_available:  boolean
  vsearch_available: boolean
}

export interface JobUpdateEvent {
  type: 'job_update'
  data: Job
}

export interface StageUpdateEvent {
  type:  'stage_update'
  data: { study: string; run: string | null; stage: string; status: StageStatus }
}


export interface FilterPreset {
  name:        string
  label:       string
  file:        string
  description: string
}

export interface ApplyPresetResult {
  preset:      string
  rows_before: number
  rows_after:  number
  filters:     Record<string, { include?: string[]; min?: number; max?: number }>
}

export interface AnalysisRequest {
  table: string
  source?: AnnotationSource
  colFilters?: Record<string, ColFilter>
  prefix?: string | null
}

export interface ChartRequest {
  table:        string
  tag:          'rank' | 'category'
  value:        string
  relative?:    boolean
  mode?:        'stacked' | 'grouped'
  subgroup?:    string | null
  top_n?:       number
  colFilters?:  Record<string, ColFilter>
}

export interface CrossRunChartRequest extends ChartRequest {
  runs: ComparisonRunSpec[]
}

export interface ComparisonRunSpec {
  run: string
  group?: string | null
  prefix?: string | null
  source?: AnnotationSource
}

/** Expand pooled runs into per-subgroup ComparisonRunSpecs. */
export function expandRunSpecs(
  items: Pick<Run, 'name' | 'pooled' | 'subgroups'>[],
  group?: string | null,
): ComparisonRunSpec[] {
  return items.flatMap(item =>
    item.pooled && item.subgroups.length > 0
      ? item.subgroups.map(prefix => ({ run: item.name, group: group ?? null, prefix }))
      : [{ run: item.name, group: group ?? null }]
  )
}

export interface ComparisonRequest extends AnalysisRequest {
  runs: ComparisonRunSpec[]
  aggregate?: boolean
}

export interface PermanovaResult {
  text: string
  r2: number | null
  f_statistic: number | null
  p_value: number | null
}

export interface ApiError {
  error:   string
  message: string
  detail?: string
}

export type AnnotationSource = 'VSEARCH' | 'DADA2'

export interface AnnotationMeta {
  table:        string
  source:       AnnotationSource
  status:       'missing' | 'fresh' | 'stale'
  rows:         number | null
  generated_at: number | null
}

export interface CategoryInfo {
  name:    string
  colour?: string
}

export interface CategorySet {
  name:               string
  label:              string
  description:        string
  categories:         CategoryInfo[]
  unassigned_colour?: string
}

export interface CompositionCategoryStats {
  rows:          number
  reads:         number
  reads_percent: number
}

export interface CompositionBuildResult {
  table:        string
  source:       AnnotationSource
  category_set: string
  total_rows:   number
  total_reads:  number
  categories:   Record<string, CompositionCategoryStats>
}

export interface ContaminationStats {
  yes:        { rows: number; reads: number }
  no:         { rows: number; reads: number }
  unassigned: { rows: number; reads: number }
  total:      { rows: number; reads: number }
}

export interface VennSet {
  name: string
  taxa: string[]
}

export interface VennResult {
  sets: VennSet[]
  rank: string
}

export interface VennRequest {
  runs: ComparisonRunSpec[]
  table: string
  rank: string
  source?: AnnotationSource
}

export interface CategorySetSaveRequest {
  base:         string
  colours:      Record<string, string>
  label?:       string
  description?: string
}

export interface CompositionSummaryRequest {
  category_set: string
  subgroup?:    string | null
}

export interface ChartCosmetics {
  layout?: Record<string, unknown>
  traces?: Record<string, Record<string, unknown>>
}
export type ChartCosmeticsMap = Record<string, ChartCosmetics>
export interface ChartCosmeticsPatch extends ChartCosmetics {
  chart_type: string
  clear?: boolean
}
