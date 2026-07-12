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
  alphaFig, loading, runAlpha,
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
      </div>

      {alphaFig != null && (
        <>
          <AlphaMetricToggles metrics={metrics} toggle={toggle} />
          <PlotlyChart figure={filteredAlpha} heightRatio={0.48} />
        </>
      )}
    </div>
  )
}
