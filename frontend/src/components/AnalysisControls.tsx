// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { PlotlyChart } from './PlotlyChart'
import { useAlphaMetricFilter, AlphaMetricToggles } from './alphaMetrics'
import type { UseAnalysisResult } from '../hooks/useAnalysis'

interface AnalysisControlsProps extends UseAnalysisResult {
  /** Truthy when analysis is ready (e.g. a table is selected). */
  body: unknown
  children?: React.ReactNode
}

export function AnalysisControls({
  ranks, rank, setRank, relative, setRelative, pool, setPool,
  alphaFig, taxaFig, loading, runAlpha, runTaxaBar,
  body, children,
}: AnalysisControlsProps) {
  const { filtered: filteredAlpha, metrics, toggle } = useAlphaMetricFilter(alphaFig)

  return (
    <div style={{ marginTop: 24 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 12, flexWrap: 'wrap' }}>
        {children}

        <button className="btn" onClick={runAlpha} disabled={loading || !body}>
          {loading ? 'Computing...' : 'Alpha Diversity'}
        </button>

        {ranks.length > 0 && !!body && (
          <>
            <select value={rank ?? ''} onChange={e => setRank(e.target.value)}
              style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid var(--color-border)',
                       fontSize: '.82rem', background: 'var(--color-bg)' }}>
              {ranks.map(r => <option key={r} value={r}>{r}</option>)}
            </select>
            <label style={{ fontSize: '.82rem', display: 'flex', alignItems: 'center', gap: 4 }}>
              <input type="checkbox" checked={relative} onChange={e => setRelative(e.target.checked)} />
              Relative
            </label>
            <label style={{ fontSize: '.82rem', display: 'flex', alignItems: 'center', gap: 4 }}>
              <input type="checkbox" checked={pool} onChange={e => setPool(e.target.checked)} />
              Pool
            </label>
            <button className="btn" onClick={runTaxaBar} disabled={loading || !rank}>
              Taxa Bar
            </button>
          </>
        )}
      </div>

      {alphaFig != null && (
        <>
          <AlphaMetricToggles metrics={metrics} toggle={toggle} />
          <PlotlyChart figure={filteredAlpha} heightRatio={0.48} />
        </>
      )}
      {taxaFig != null && <PlotlyChart figure={taxaFig} heightRatio={0.3} />}
    </div>
  )
}
