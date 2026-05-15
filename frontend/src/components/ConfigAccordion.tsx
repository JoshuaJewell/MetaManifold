// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useState } from 'react'
import {
  STAGE_CONFIG_PREFIXES,
  STAGE_LABELS,
  StageConfig,
} from './PipelineStages'
import type { ConfigMap, ConfigSource } from '../api/types'

const VISIBLE_STAGES = Object.keys(STAGE_CONFIG_PREFIXES) as (keyof typeof STAGE_CONFIG_PREFIXES)[]

export function ConfigAccordion({ configMap, study, run, group, onConfigChanged, patchFn, deleteFn, sourceLevel, overrides }: {
  configMap: ConfigMap
  study: string
  run: string
  group?: string
  onConfigChanged: () => void
  patchFn?: (study: string, run: string, body: Record<string, unknown>, group?: string) => Promise<ConfigMap>
  deleteFn?: (study: string, run: string, key: string, group?: string) => Promise<ConfigMap>
  sourceLevel?: ConfigSource
  overrides?: Record<string, string[]> | null
}) {
  const [expanded, setExpanded] = useState<string | null>(null)

  return (
    <div>
      {VISIBLE_STAGES.map(stage => {
        const prefixes = STAGE_CONFIG_PREFIXES[stage]
        const hasKeys = prefixes.some(p => Object.keys(configMap).some(k => k.startsWith(p)))
        // Always show the global section at the default config level so your_name can be set.
        if (!hasKeys && !(stage === 'global' && sourceLevel === 'default')) return null
        const isExpanded = expanded === stage
        return (
          <div key={stage} style={{ marginBottom: 4 }}>
            <div
              style={{ cursor: 'pointer', fontWeight: 600, fontSize: '.85rem', padding: '4px 0' }}
              onClick={() => setExpanded(isExpanded ? null : stage)}
            >
              <span style={{ fontSize: '.8rem', marginRight: 6, opacity: .65 }}>{isExpanded ? 'v' : '>'}</span>
              {STAGE_LABELS[stage]}
            </div>
            {isExpanded && (
              <StageConfig
                configMap={configMap}
                prefixes={prefixes}
                study={study}
                run={run}
                group={group}
                onConfigChanged={onConfigChanged}
                patchFn={patchFn}
                deleteFn={deleteFn}
                sourceLevel={sourceLevel}
                overrides={overrides}
              />
            )}
          </div>
        )
      })}
    </div>
  )
}
