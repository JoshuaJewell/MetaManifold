// (c) 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import Plotly from 'plotly.js-dist-min'
import PlotlyEditor, {
  PanelMenuWrapper, StyleLayoutPanel, StyleTracesPanel, StyleAxesPanel, StyleLegendPanel,
} from 'react-chart-editor'
import 'react-chart-editor/lib/react-chart-editor.css'
import './chartEditor.css'

//## Curated chart editor (Style panels only)
export default function ChartEditorInner({ state, onUpdate }: {
  state: { data: unknown[]; layout: Record<string, unknown>; frames: unknown[] }
  onUpdate: (data: unknown[], layout: Record<string, unknown>, frames: unknown[]) => void
}) {
  return (
    <PlotlyEditor
      data={state.data} layout={state.layout} frames={state.frames}
      config={{ editable: true, displaylogo: false }} plotly={Plotly}
      onUpdate={onUpdate} useResizeHandler
    >
      <PanelMenuWrapper>
        <StyleLayoutPanel group="Style" name="General" />
        <StyleTracesPanel group="Style" name="Traces" />
        <StyleAxesPanel group="Style" name="Axes" />
        <StyleLegendPanel group="Style" name="Legend" />
      </PanelMenuWrapper>
    </PlotlyEditor>
  )
}
