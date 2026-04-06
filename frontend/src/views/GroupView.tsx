import { Link, useParams, useNavigate } from 'react-router-dom'
import { useCallback, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import { Skeleton } from '../components/Skeleton'
import { NameDialog } from '../components/NameDialog'
import { RunCard } from '../components/CardActions'
import { useToast } from '../components/Toast'
import { ComparisonPanel } from '../components/ComparisonPanel'
import { expandRunSpecs } from '../api/types'
import { ConfigAccordion } from '../components/ConfigAccordion'

type Dialog =
  | { mode: 'rename-group' }
  | { mode: 'new-run' }
  | { mode: 'rename-run'; name: string }

export function GroupView({ groupName }: { groupName?: string } = {}) {
  const { study, group: groupParam } = useParams<{ study: string; group?: string }>()
  const group = groupName ?? groupParam
  const navigate = useNavigate()
  const toast    = useToast()
  const [dialog, setDialog]   = useState<Dialog | null>(null)


  const runsFetcher = useCallback(() => api.runs.listGroup(study!, group!), [study, group])
  const { data: runs, loading, error, refetch } = useApi(runsFetcher)

  const configFetcher = useCallback(() => api.config.getGroup(study!, group!), [study, group])
  const { data: configMap, refetch: refetchConfig } = useApi(configFetcher)

  const overridesFetcher = useCallback(() => api.config.groupOverrides(study!, group!), [study, group])
  const { data: overrides } = useApi(overridesFetcher)

  const patchFn = useCallback(
    (_study: string, _group: string, body: Record<string, unknown>) =>
      api.config.patchGroup(study!, group!, body),
    [study, group],
  )

  const deleteFn = useCallback(
    (_study: string, _group: string, key: string) =>
      api.config.deleteGroup(study!, group!, key),
    [study, group],
  )

  const handleRenameGroup = async (newName: string) => {
    await api.groups.rename(study!, group!, newName)
    setDialog(null)
    toast.success(`Renamed to '${newName}'`)
    navigate(`/${study}/${newName}`)
  }

  const handleDeleteGroup = async () => {
    if (!window.confirm(`Delete group '${group}' and all its runs? This cannot be undone.`)) return
    await api.groups.delete(study!, group!)
    toast.success(`Group '${group}' deleted`)
    navigate(`/${study}`)
  }

  const handleNewRun = async (name: string) => {
    await api.runs.create(study!, name)
    setDialog(null)
    toast.success(`Run '${name}' created`)
    refetch()
  }

  const handleRenameRun = async (oldName: string, newName: string) => {
    await api.runs.rename(study!, oldName, newName)
    setDialog(null)
    toast.success(`Renamed to '${newName}'`)
    refetch()
  }

  const handleDeleteRun = async (name: string) => {
    if (!window.confirm(`Delete run '${name}'? This cannot be undone.`)) return
    await api.runs.delete(study!, name)
    toast.success(`Run '${name}' deleted`)
    refetch()
  }

  return (
    <>
      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <h1>{group}</h1>
          {runs && (
            <p>
              {runs.length} run{runs.length !== 1 ? 's' : ''}
              {' - '}
              <Link to={`/${study}`} style={{ color: 'var(--color-muted-fg)' }}>{study}</Link>
            </p>
          )}
        </div>
        <div style={{ display: 'flex', gap: 8, flexShrink: 0 }}>
          <button className="btn" onClick={() => setDialog({ mode: 'rename-group' })}>Rename</button>
          <button className="btn" style={{ color: '#c92a2a', borderColor: '#ffc9c9' }} onClick={handleDeleteGroup}>Delete</button>
        </div>
      </div>

      <h2 style={{ fontSize: '1rem', marginBottom: 8 }}>Group Config</h2>
      {configMap && (
        <div style={{ marginBottom: 24 }}>
          <ConfigAccordion
            configMap={configMap}
            study={study!}
            run={group!}
            onConfigChanged={refetchConfig}
            patchFn={patchFn}
            deleteFn={deleteFn}
            sourceLevel="group"
            overrides={overrides}
          />
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <h2 style={{ fontSize: '1rem' }}>Runs</h2>
        <button className="btn" style={{ padding: '3px 10px', fontSize: '.82rem' }} onClick={() => setDialog({ mode: 'new-run' })}>+ New Run</button>
      </div>

      {loading && <Skeleton lines={3} />}
      {error && <p className="error-msg">{error}</p>}

      {runs && (
        <div className="card-grid">
          {runs.map(run => (
            <RunCard
              key={run.name}
              name={run.name}
              to={`/${study}/${group}/${run.name}`}
              sampleCount={run.sample_count}
              stages={run.stages}
              onRename={() => setDialog({ mode: 'rename-run', name: run.name })}
              onDelete={() => handleDeleteRun(run.name)}
            />
          ))}
        </div>
      )}

      {runs && runs.length >= 2 && (
        <ComparisonPanel
          study={study!}
          runs={expandRunSpecs(runs, group)}
        />
      )}

      {dialog?.mode === 'rename-group' && (
        <NameDialog
          title="Rename Group"
          initialValue={group}
          placeholder="group-name"
          onConfirm={handleRenameGroup}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.mode === 'new-run' && (
        <NameDialog
          title="New Run"
          placeholder="run-name"
          onConfirm={handleNewRun}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.mode === 'rename-run' && (
        <NameDialog
          title="Rename Run"
          initialValue={dialog.name}
          placeholder="run-name"
          onConfirm={name => handleRenameRun(dialog.name, name)}
          onClose={() => setDialog(null)}
        />
      )}
    </>
  )
}

