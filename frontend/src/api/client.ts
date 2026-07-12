import type {
  Study, StudySummary, Run,
  Job, JobStatus,
  TableMeta, TablePage, TableQuery, ColFilter, DistinctInfo,
  FilterPreset, ApplyPresetResult,
  ConfigMap,
  DatabaseEntry,
  ApiError,
  AnnotationSource, AnnotationMeta, ContaminationStats,
  AnalysisRequest, ComparisonRequest, PermanovaResult,
  ChartRequest, CrossRunChartRequest,
  CategorySet, CategorySetSaveRequest, CompositionBuildResult,
  CompositionSummaryRequest,
  VennRequest, VennResult,
  ChartCosmeticsMap, ChartCosmeticsPatch,
} from './types'

// Base URL for the backend API. Empty string means same-origin.
// Set "apiBase" in config.json (e.g. "https://bioserver:8080") for split deployments.
let _apiBase = ''

/** Called once at startup from main.tsx to load runtime config. */
export async function loadConfig(): Promise<void> {
  try {
    const res = await fetch('/config.json')
    if (res.ok) {
      const cfg = await res.json()
      _apiBase = (cfg.apiBase as string ?? '').replace(/\/+$/, '')
    }
  } catch {
    // Missing or malformed config.json - default to same-origin
  }
}

/** Prepend the API base to a path that starts with "/" */
export function apiUrl(path: string): string {
  return _apiBase ? `${_apiBase}${path}` : path
}

async function rawPost(path: string, body: unknown): Promise<Response> {
  const res = await fetch(apiUrl(path), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    const err: ApiError = await res.json().catch(() => ({
      error: 'network_error', message: res.statusText,
    }))
    throw Object.assign(new Error(err.message), { apiError: err, status: res.status })
  }
  return res
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(apiUrl(path), {
    cache: 'no-store',
    headers: { 'Content-Type': 'application/json', ...init?.headers },
    ...init,
  })
  if (!res.ok) {
    const err: ApiError = await res.json().catch(() => ({
      error: 'network_error', message: res.statusText,
    }))
    throw Object.assign(new Error(err.message), { apiError: err, status: res.status })
  }
  return res.json() as Promise<T>
}

const get  = <T>(path: string)                       => request<T>(path)
const post = <T>(path: string, body?: unknown)       => request<T>(path, { method: 'POST',  body: body !== undefined ? JSON.stringify(body) : undefined })
const patch = <T>(path: string, body?: unknown)      => request<T>(path, { method: 'PATCH', body: body !== undefined ? JSON.stringify(body) : undefined })
const del  = <T>(path: string)                       => request<T>(path, { method: 'DELETE' })

/** Append ?group=X query parameter when group is provided. */
const gq = (group?: string | null) =>
  group ? `?group=${encodeURIComponent(group)}` : ''

export const api = {
  studies: {
    list:   ()               => get<StudySummary[]>('/api/v1/studies'),
    get:    (study: string)  => get<Study>(`/api/v1/studies/${study}`),
    create: (name: string)   => post<Study>('/api/v1/studies', { name }),
    rename: (study: string, name: string) => post<Study>(`/api/v1/studies/${study}/rename`, { name }),
    delete: (study: string)  => del<{ deleted: string }>(`/api/v1/studies/${study}`),
  },

  groups: {
    create: (study: string, name: string)               => post<{ study: string; name: string }>(`/api/v1/studies/${study}/groups`, { name }),
    rename: (study: string, group: string, name: string) => post<{ study: string; name: string }>(`/api/v1/studies/${study}/groups/${group}/rename`, { name }),
    delete: (study: string, group: string)              => del<{ deleted: string }>(`/api/v1/studies/${study}/groups/${group}`),
  },

  runs: {
    list:      (study: string)                          => get<Run[]>(`/api/v1/studies/${study}/runs`),
    get:       (study: string, run: string, group?: string | null) => get<Run>(`/api/v1/studies/${study}/runs/${run}${gq(group)}`),
    listGroup: (study: string, group: string)            => get<Run[]>(`/api/v1/studies/${study}/groups/${group}/runs`),
    create:    (study: string, name: string)             => post<Run>(`/api/v1/studies/${study}/runs`, { name }),
    rename:    (study: string, run: string, name: string, group?: string | null) => post<Run>(`/api/v1/studies/${study}/runs/${run}/rename${gq(group)}`, { name }),
    delete:    (study: string, run: string, group?: string | null) => del<{ deleted: string }>(`/api/v1/studies/${study}/runs/${run}${gq(group)}`),
  },

  pipeline: {
    runStudy: (study: string)                       => post<Job>(`/api/v1/studies/${study}/pipeline`),
    runRun:   (study: string, run: string, group?: string | null) => post<Job>(`/api/v1/studies/${study}/runs/${run}/pipeline${gq(group)}`),
    runStage: (study: string, run: string, stage: string, group?: string | null) =>
                                                       post<Job>(`/api/v1/studies/${study}/runs/${run}/stages/${stage}${gq(group)}`),
  },

  jobs: {
    list:   (opts?: { study?: string; status?: JobStatus }) => {
      const p = new URLSearchParams()
      if (opts?.study)  p.set('study',  opts.study)
      if (opts?.status) p.set('status', opts.status)
      const qs = p.size ? `?${p}` : ''
      return get<Job[]>(`/api/v1/jobs${qs}`)
    },
    get:    (id: string) => get<Job>(`/api/v1/jobs/${id}`),
    cancel: (id: string) => del<void>(`/api/v1/jobs/${id}`),
  },

  results: {
    runTables:    (study: string, run: string, group?: string | null) => get<TableMeta[]>(`/api/v1/studies/${study}/runs/${run}/results/tables${gq(group)}`),
    runTable:     (study: string, run: string, id: string, q: TableQuery, group?: string | null) =>
      post<TablePage>(`/api/v1/studies/${study}/runs/${run}/results/tables/${id}/query${gq(group)}`, q),
    distinctValues: (study: string, run: string, id: string, column: string, activeFilters?: Record<string, ColFilter>, group?: string | null, keywordFilter?: string) =>
      post<DistinctInfo>(`/api/v1/studies/${study}/runs/${run}/results/tables/${id}/distinct/${column}${gq(group)}`,
        {
          ...(activeFilters ? { colFilters: activeFilters } : {}),
          ...(keywordFilter ? { filter: keywordFilter } : {}),
        }),
    saveTable: (study: string, run: string, id: string, name: string,
                colFilters?: Record<string, ColFilter>, sortBy?: string, sortDir?: string, group?: string | null) =>
      post<{ name: string; path: string; rows: number }>(
        `/api/v1/studies/${study}/runs/${run}/results/tables/${id}/save${gq(group)}`,
        { name, colFilters, sortBy, sortDir }),
    deleteTable: (study: string, run: string, id: string, group?: string | null) =>
      del<{ deleted: string }>(`/api/v1/studies/${study}/runs/${run}/results/tables/${id}${gq(group)}`),
    otuMembers: (study: string, run: string, otu: string, group?: string | null) =>
      get<{ otu: string; columns: string[]; rows: Record<string, unknown>[] }>(
        `/api/v1/studies/${study}/runs/${run}/results/otu-members/${otu}${gq(group)}`),
    otuCounts: (study: string, run: string, group?: string | null) =>
      get<{ counts: Record<string, number> }>(
        `/api/v1/studies/${study}/runs/${run}/results/otu-counts${gq(group)}`),
    qcOutputs: (study: string, run: string, group?: string | null) =>
      get<{ has_report: boolean; report_url: string | null }>(
        `/api/v1/studies/${study}/runs/${run}/results/qc${gq(group)}`),
    dada2Outputs: (study: string, run: string, group?: string | null) =>
      get<{ figures: { name: string; label: string; url: string }[]; has_stats: boolean; logs: { name: string; url: string }[]; config: Record<string, unknown> }>(
        `/api/v1/studies/${study}/runs/${run}/results/dada2${gq(group)}`),
    dada2Stats: (study: string, run: string, group?: string | null) =>
      get<{ columns: string[]; rows: Record<string, unknown>[] }>(
        `/api/v1/studies/${study}/runs/${run}/results/dada2/stats${gq(group)}`),
    exportTable: async (study: string, run: string, id: string,
                        colFilters?: Record<string, ColFilter>, sortBy?: string, sortDir?: string, group?: string | null) => {
      const res = await rawPost(
        `/api/v1/studies/${study}/runs/${run}/results/tables/${id}/export${gq(group)}`,
        { colFilters, sortBy, sortDir, filename: `${study}_${run}_filtered.xlsx` })
      const blob = await res.blob()
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `${study}_${run}_filtered.xlsx`
      a.click()
      URL.revokeObjectURL(url)
    },
  },

  presets: {
    list: () => get<FilterPreset[]>('/api/v1/filter-presets'),
    apply: (study: string, run: string, table: string, preset: string, group?: string | null) =>
      post<ApplyPresetResult>(`/api/v1/studies/${study}/runs/${run}/results/tables/${table}/apply-preset${gq(group)}`, { preset }),
    save: (name: string, filters: Record<string, ColFilter>, description?: string) =>
      post<FilterPreset>(`/api/v1/filter-presets/${name}`, { filters, description }),
    delete: (name: string) => del<{ deleted: string }>(`/api/v1/filter-presets/${name}`),
  },

  primers: {
    list: () => get<string[]>('/api/v1/primers'),
  },

  config: {
    getDefault:    ()                                => get<ConfigMap>('/api/v1/config'),
    patchDefault:  (body: Record<string, unknown>)   => patch<ConfigMap>('/api/v1/config', body),
    deleteDefault: (key: string)                     => del<ConfigMap>(`/api/v1/config/${encodeURIComponent(key)}`),
    getStudy:    (study: string)                     => get<ConfigMap>(`/api/v1/studies/${study}/config`),
    patchStudy:  (study: string, body: Record<string, unknown>) => patch<ConfigMap>(`/api/v1/studies/${study}/config`, body),
    deleteStudy: (study: string, key: string)        => del<ConfigMap>(`/api/v1/studies/${study}/config/${key}`),
    getRun:      (study: string, run: string, group?: string | null) => get<ConfigMap>(`/api/v1/studies/${study}/runs/${run}/config${gq(group)}`),
    patchRun:    (study: string, run: string, body: Record<string, unknown>, group?: string | null) =>
                                                        patch<ConfigMap>(`/api/v1/studies/${study}/runs/${run}/config${gq(group)}`, body),
    deleteRun:   (study: string, run: string, key: string, group?: string | null) =>
                                                        del<ConfigMap>(`/api/v1/studies/${study}/runs/${run}/config/${key}${gq(group)}`),
    studyOverrides: (study: string) => get<Record<string, string[]>>(`/api/v1/studies/${study}/config/overrides`),
    groupOverrides: (study: string, group: string) => get<Record<string, string[]>>(`/api/v1/studies/${study}/groups/${group}/config/overrides`),
    getGroup:    (study: string, group: string)          => get<ConfigMap>(`/api/v1/studies/${study}/groups/${group}/config`),
    patchGroup:  (study: string, group: string, body: Record<string, unknown>) =>
                                                        patch<ConfigMap>(`/api/v1/studies/${study}/groups/${group}/config`, body),
    deleteGroup: (study: string, group: string, key: string) =>
                                                        del<ConfigMap>(`/api/v1/studies/${study}/groups/${group}/config/${key}`),
  },

  analysis: {
    alpha:         (study: string, run: string, body: AnalysisRequest, group?: string | null) =>
                     post<unknown>(`/api/v1/studies/${study}/runs/${run}/analysis/alpha${gq(group)}`, body),
    chart:         (study: string, run: string, body: ChartRequest, group?: string | null) =>
                     post<unknown>(`/api/v1/studies/${study}/runs/${run}/analysis/chart${gq(group)}`, body),
    pipelineStats: (study: string, run: string, group?: string | null) =>
                     get<unknown>(`/api/v1/studies/${study}/runs/${run}/analysis/pipeline-stats${gq(group)}`),
    ranks:         (study: string, run: string, opts?: { table?: string; group?: string | null; source?: AnnotationSource }) => {
                     const query = new URLSearchParams()
                     if (opts?.group) query.set('group', opts.group)
                     if (opts?.table) query.set('table', opts.table)
                     if (opts?.source) query.set('source', opts.source)
                     const qs = query.size ? `?${query.toString()}` : ''
                     return get<string[]>(`/api/v1/studies/${study}/runs/${run}/analysis/ranks${qs}`)
                   },
    compareAlpha:  (study: string, body: ComparisonRequest) =>
                     post<unknown>(`/api/v1/studies/${study}/analysis/alpha`, body),
    chartCompare:  (study: string, body: CrossRunChartRequest) =>
                     post<unknown>(`/api/v1/studies/${study}/analysis/chart`, body),
    nmds:          (study: string, body: ComparisonRequest) =>
                     post<unknown>(`/api/v1/studies/${study}/analysis/nmds`, body),
    permanova:     (study: string, body: ComparisonRequest) =>
                     post<PermanovaResult>(`/api/v1/studies/${study}/analysis/permanova`, body),
    capabilities:  () => get<{ r_available: boolean }>('/api/v1/capabilities'),
    venn:          (study: string, body: VennRequest) =>
                     post<VennResult>(`/api/v1/studies/${study}/analysis/venn`, body),
  },

  annotations: {
    list: (study: string, run: string, source: AnnotationSource, group?: string | null) =>
      get<AnnotationMeta[]>(`/api/v1/studies/${study}/runs/${run}/annotations/${source}${gq(group)}`),
    generate: (study: string, run: string, source: AnnotationSource, table: string, group?: string | null) =>
      post<AnnotationMeta & { output_path: string }>(`/api/v1/studies/${study}/runs/${run}/annotations/${source}/generate${gq(group)}`, { table }),
    query: (study: string, run: string, source: AnnotationSource, table: string, q: TableQuery, group?: string | null) =>
      post<TablePage>(`/api/v1/studies/${study}/runs/${run}/annotations/${source}/${table}/query${gq(group)}`, q),
    distinct: (study: string, run: string, source: AnnotationSource, table: string, column: string, activeFilters?: Record<string, ColFilter>, group?: string | null, keywordFilter?: string) =>
      post<DistinctInfo>(`/api/v1/studies/${study}/runs/${run}/annotations/${source}/${table}/distinct/${column}${gq(group)}`,
        {
          ...(activeFilters ? { colFilters: activeFilters } : {}),
          ...(keywordFilter ? { filter: keywordFilter } : {}),
        }),
    updateContamination: (study: string, run: string, source: AnnotationSource, table: string,
                          rank: string, taxon: string, status: string, group?: string | null) =>
      patch<{ table: string; rank: string; taxon: string; status: string; rows_affected: number }>(
        `/api/v1/studies/${study}/runs/${run}/annotations/${source}/${table}/contamination${gq(group)}`,
        { rank, taxon, status }),
    updateBlastAssignment: (
      study: string, run: string, source: AnnotationSource, table: string,
      sequence: string, blastAssignment: string, group?: string | null,
    ) =>
      patch<{ table: string; sequence: string; blast_assignment: string; rows_affected: number }>(
        `/api/v1/studies/${study}/runs/${run}/annotations/${source}/${table}/blast-assignment${gq(group)}`,
        { sequence, blast_assignment: blastAssignment }),
    contaminationStats: (study: string, run: string, source: AnnotationSource, table: string, group?: string | null) =>
      get<ContaminationStats>(`/api/v1/studies/${study}/runs/${run}/annotations/${source}/${table}/contamination/stats${gq(group)}`),
    addFuncdbEntry: (entry: Record<string, string>, modified_by?: string) =>
      post<Record<string, string>>('/api/v1/funcdb/entries', { ...entry, modified_by: modified_by ?? '' }),
    exportCsv: (study: string, run: string, source: AnnotationSource, table: string, group?: string | null) => {
      const url = apiUrl(`/api/v1/studies/${study}/runs/${run}/annotations/${source}/${table}/export${gq(group)}`)
      const a = document.createElement('a')
      a.href = url
      a.download = `${table}.csv`
      a.click()
    },
  },

  composition: {
    categorySets: () => get<CategorySet[]>('/api/v1/category-sets'),
    saveCategorySet: (name: string, body: CategorySetSaveRequest) =>
      post<CategorySet>(`/api/v1/category-sets/${encodeURIComponent(name)}`, body),
    deleteCategorySet: (name: string) =>
      del<{ deleted: string }>(`/api/v1/category-sets/${encodeURIComponent(name)}`),
    summary: (study: string, run: string, body: CompositionSummaryRequest, group?: string | null) =>
      post<CompositionBuildResult>(
        `/api/v1/studies/${study}/runs/${run}/composition/summary${gq(group)}`, body),
    query: (study: string, run: string, source: AnnotationSource, q: TableQuery,
            group?: string | null, categorySet?: string) =>
      post<TablePage>(
        `/api/v1/studies/${study}/runs/${run}/composition/${source}/query${gq(group)}`,
        { ...q, ...(categorySet ? { category_set: categorySet } : {}) }),
    distinct: (study: string, run: string, source: AnnotationSource, column: string,
               activeFilters?: Record<string, ColFilter>, group?: string | null,
               categorySet?: string, keywordFilter?: string) =>
      post<DistinctInfo>(
        `/api/v1/studies/${study}/runs/${run}/composition/${source}/distinct/${column}${gq(group)}`,
        {
          ...(activeFilters ? { colFilters: activeFilters } : {}),
          ...(categorySet ? { category_set: categorySet } : {}),
          ...(keywordFilter ? { filter: keywordFilter } : {}),
        }),
  },

  chartCosmetics: {
    get:   (study: string) => get<ChartCosmeticsMap>(`/api/v1/studies/${study}/chart-cosmetics`),
    patch: (study: string, body: ChartCosmeticsPatch) =>
      patch<ChartCosmeticsMap>(`/api/v1/studies/${study}/chart-cosmetics`, body),
  },

  databases: {
    list:     ()             => get<DatabaseEntry[]>('/api/v1/databases'),
    download: (key: string)  => post<Job>(`/api/v1/databases/${key}/download`),
  },
}
