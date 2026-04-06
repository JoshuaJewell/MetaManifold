// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from '../components/Toast'
import type { AnalysisRequest, AnnotationSource } from '../api/types'

export interface UseAnalysisOpts {
  study: string
  run: string
  group?: string | null
  table: string | null
  source?: AnnotationSource
  colFilters?: Record<string, ColFilter>
  prefix?: string | null
  /** When false, rank fetching is suppressed (e.g. table not yet ready). Default true. */
  enabled?: boolean
}

type ColFilter = { include?: string[]; min?: number; max?: number }

export interface UseAnalysisResult {
  ranks: string[]
  rank: string | null
  setRank: (rank: string | null) => void
  relative: boolean
  setRelative: (relative: boolean) => void
  alphaFig: unknown
  taxaFig: unknown
  loading: boolean
  runAlpha: () => Promise<void>
  runTaxaBar: () => Promise<void>
  resetFigures: () => void
}

export function useAnalysis(opts: UseAnalysisOpts): UseAnalysisResult {
  const { study, run, group, table, source, colFilters, prefix, enabled = true } = opts
  const toast = useToast()

  const [ranks, setRanks]       = useState<string[]>([])
  const [rank, setRank]         = useState<string | null>(null)
  const [relative, setRelative] = useState(true)
  const [alphaFig, setAlphaFig] = useState<unknown>(null)
  const [taxaFig, setTaxaFig]   = useState<unknown>(null)
  const [loading, setLoading]   = useState(false)

  useEffect(() => {
    if (!table || !enabled) {
      setRanks([])
      return
    }
    api.analysis.ranks(study, run, { table, group: group ?? undefined, source })
      .then(setRanks)
      .catch(() => setRanks([]))
  }, [study, run, group, source, table, enabled])

  useEffect(() => {
    if (ranks.length === 0) { setRank(null); return }
    if (!rank || !ranks.includes(rank)) setRank(ranks[ranks.length - 1])
  }, [ranks, rank])

  const body = useMemo((): AnalysisRequest | null => {
    if (!table) return null
    return { table, source, colFilters, prefix: prefix || undefined }
  }, [table, source, colFilters, prefix])

  const runAlpha = useCallback(async () => {
    if (!body) return
    setLoading(true)
    try {
      setAlphaFig(await api.analysis.alpha(study, run, body, group))
    } catch (err) {
      toast.error('Alpha analysis failed: ' + (errorMessage(err)))
    } finally { setLoading(false) }
  }, [body, group, run, study, toast])

  const runTaxaBar = useCallback(async () => {
    if (!rank || !body) return
    setLoading(true)
    try {
      setTaxaFig(await api.analysis.taxaBar(study, run,
        { ...body, rank, top_n: 15, relative }, group))
    } catch (err) {
      toast.error('Taxa bar failed: ' + (errorMessage(err)))
    } finally { setLoading(false) }
  }, [body, group, rank, relative, run, study, toast])

  const resetFigures = useCallback(() => {
    setAlphaFig(null)
    setTaxaFig(null)
  }, [])

  return { ranks, rank, setRank, relative, setRelative, alphaFig, taxaFig, loading, runAlpha, runTaxaBar, resetFigures }
}
