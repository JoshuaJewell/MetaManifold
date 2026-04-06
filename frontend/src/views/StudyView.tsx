import { Link, useParams, useNavigate } from 'react-router-dom'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { useJobRefetch } from '../hooks/useJobEvents'
import { api } from '../api/client'
import { Skeleton } from '../components/Skeleton'
import { NameDialog } from '../components/NameDialog'
import { CardActions, RunCard } from '../components/CardActions'
import { useToast } from '../components/Toast'
import { ComparisonPanel } from '../components/ComparisonPanel'
import type { ComparisonRunSpec, Run } from '../api/types'
import { expandRunSpecs } from '../api/types'
import { ConfigAccordion } from '../components/ConfigAccordion'

type GroupedRun = Run & { group?: string | null }

type Dialog =
  | { mode: 'rename-study' }
  | { mode: 'new-group' }
  | { mode: 'rename-group'; name: string }
  | { mode: 'new-run' }
  | { mode: 'rename-run'; name: string }

export function StudyView() {
  const { study } = useParams<{ study: string }>()
  const navigate  = useNavigate()
  const toast     = useToast()
  const [dialog, setDialog] = useState<Dialog | null>(null)


  const fetcher = useCallback(() => api.runs.list(study!), [study])
  const { data: runs, loading, error, refetch } = useApi(fetcher)

  const studyFetcher = useCallback(() => api.studies.get(study!), [study])
  const { data: detail, refetch: refetchDetail } = useApi(studyFetcher)

  const configFetcher = useCallback(() => api.config.getStudy(study!), [study])
  const { data: configMap, refetch: refetchConfig } = useApi(configFetcher)

  const overridesFetcher = useCallback(() => api.config.studyOverrides(study!), [study])
  const { data: overrides } = useApi(overridesFetcher)

  const patchFn = useCallback(
    (_study: string, _run: string, body: Record<string, unknown>) =>
      api.config.patchStudy(study!, body),
    [study],
  )

  const deleteFn = useCallback(
    (_study: string, _run: string, key: string) =>
      api.config.deleteStudy(study!, key),
    [study],
  )

  // Fetch runs from each group for the comparison panel
  const [groupRuns, setGroupRuns] = useState<GroupedRun[]>([])
  useEffect(() => {
    if (!detail?.groups?.length) { setGroupRuns([]); return }
    let cancelled = false
    Promise.all(
      detail.groups.map(async (g: string) => {
        const gRuns = await api.runs.listGroup(study!, g)
        return gRuns.map(r => ({ ...r, group: g }))
      })
    ).then(results => {
      if (!cancelled) setGroupRuns(results.flat())
    })
    return () => { cancelled = true }
  }, [detail?.groups, study])

  const allComparisonRuns = useMemo<ComparisonRunSpec[]>(() => {
    const ungrouped = expandRunSpecs(runs ?? [])
    const grouped = groupRuns.flatMap(r => expandRunSpecs([r], r.group))
    return [...ungrouped, ...grouped]
  }, [runs, groupRuns])

  const jobFilter = useMemo(() => ({ study: study! }), [study])
  useJobRefetch(refetch, jobFilter)

  const refetchAll = useCallback(() => { refetch(); refetchDetail() }, [refetch, refetchDetail])

  const runPipeline = async () => {
    await api.pipeline.runStudy(study!)
    refetch()
  }

  const handleRenameStudy = async (newName: string) => {
    await api.studies.rename(study!, newName)
    setDialog(null)
    toast.success(`Renamed to '${newName}'`)
    navigate(`/${newName}`)
  }

  const handleDeleteStudy = async () => {
    if (!window.confirm(`Delete study '${study}'? This cannot be undone.`)) return
    await api.studies.delete(study!)
    toast.success(`Study '${study}' deleted`)
    navigate('/studies')
  }

  const handleNewGroup = async (name: string) => {
    await api.groups.create(study!, name)
    setDialog(null)
    toast.success(`Group '${name}' created`)
    refetchAll()
  }

  const handleRenameGroup = async (oldName: string, newName: string) => {
    await api.groups.rename(study!, oldName, newName)
    setDialog(null)
    toast.success(`Renamed to '${newName}'`)
    refetchDetail()
  }

  const handleDeleteGroup = async (name: string) => {
    if (!window.confirm(`Delete group '${name}' and all its runs? This cannot be undone.`)) return
    await api.groups.delete(study!, name)
    toast.success(`Group '${name}' deleted`)
    refetchDetail()
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
          <h1>{study}</h1>
          {detail && (
            <p>
              {detail.run_count} run{detail.run_count !== 1 ? 's' : ''}
              {' - '}
              {detail.group_count} group{detail.group_count !== 1 ? 's' : ''}
            </p>
          )}
        </div>
        <div style={{ display: 'flex', gap: 8, flexShrink: 0 }}>
          <button className="btn" onClick={() => setDialog({ mode: 'rename-study' })}>Rename</button>
          <button className="btn" style={{ color: '#c92a2a', borderColor: '#ffc9c9' }} onClick={handleDeleteStudy}>Delete</button>
          <button className="btn btn-primary" onClick={runPipeline}>Run full pipeline</button>
        </div>
      </div>

      {loading && <Skeleton lines={3} />}
      {error   && <p className="error-msg">{error}</p>}

      <h2 style={{ fontSize: '1rem', marginBottom: 8, marginTop: 24 }}>Study Config</h2>
      {configMap && (
        <div style={{ marginBottom: 24 }}>
          <ConfigAccordion
            configMap={configMap}
            study={study!}
            run={study!}
            onConfigChanged={refetchConfig}
            patchFn={patchFn}
            deleteFn={deleteFn}
            sourceLevel="study"
            overrides={overrides}
          />
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 24, marginBottom: 8 }}>
        <h2 style={{ fontSize: '1rem' }}>Groups</h2>
        <button className="btn" style={{ padding: '3px 10px', fontSize: '.82rem' }} onClick={() => setDialog({ mode: 'new-group' })}>+ New Group</button>
      </div>
      {detail && detail.groups && detail.groups.length > 0 && (
        <div className="card-grid">
          {detail.groups.map((group: string) => (
            <div key={group} className="study-card" style={{ display: 'flex', flexDirection: 'column' }}>
              <Link
                to={`/${study}/${group}`}
                style={{ textDecoration: 'none', color: 'inherit', flex: 1 }}
              >
                <h3>{group}</h3>
              </Link>
              <CardActions
                onRename={() => setDialog({ mode: 'rename-group', name: group })}
                onDelete={() => handleDeleteGroup(group)}
              />
            </div>
          ))}
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 24, marginBottom: 8 }}>
        <h2 style={{ fontSize: '1rem' }}>Runs</h2>
        <button className="btn" style={{ padding: '3px 10px', fontSize: '.82rem' }} onClick={() => setDialog({ mode: 'new-run' })}>+ New Run</button>
      </div>

      {runs && runs.length > 0 && (
        <div className="card-grid">
          {runs.map(run => (
            <RunCard
              key={run.name}
              name={run.name}
              to={`/${study}/${run.name}`}
              sampleCount={run.sample_count}
              stages={run.stages}
              onRename={() => setDialog({ mode: 'rename-run', name: run.name })}
              onDelete={() => handleDeleteRun(run.name)}
            />
          ))}
        </div>
      )}

      {runs && runs.length === 0 && (
        <p style={{ color: 'var(--color-muted-fg)', fontSize: '.88rem' }}>No runs yet. Add FASTQ files or create a run above.</p>
      )}

      {allComparisonRuns.length >= 2 && (
        <ComparisonPanel study={study!} runs={allComparisonRuns} />
      )}

      {dialog?.mode === 'rename-study' && (
        <NameDialog
          title="Rename Study"
          initialValue={study}
          placeholder="study-name"
          onConfirm={handleRenameStudy}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.mode === 'new-group' && (
        <NameDialog
          title="New Group"
          placeholder="group-name"
          onConfirm={handleNewGroup}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.mode === 'rename-group' && (
        <NameDialog
          title="Rename Group"
          initialValue={dialog.name}
          placeholder="group-name"
          onConfirm={name => handleRenameGroup(dialog.name, name)}
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

