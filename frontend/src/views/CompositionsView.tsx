// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useCallback, useMemo, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from '../components/Toast'
import { Skeleton } from '../components/Skeleton'
import { NameDialog } from '../components/NameDialog'
import { FilterEditor } from '../components/FilterEditor'
import { CategorySetEditor } from '../components/CategorySetEditor'
import type { CompositionFilter, CompositionSet } from '../api/types'

export function CompositionsView() {
  const toast = useToast()
  const fetcher = useCallback(() => api.composition.library(), [])
  const { data: library, loading, error, refetch } = useApi(fetcher)

  const [showNewFilter, setShowNewFilter] = useState(false)
  const [showNewSet, setShowNewSet] = useState(false)

  const filterNames = useMemo(
    () => (library ? Object.keys(library.filters).sort() : []),
    [library],
  )

  const setNames = useMemo(
    () => (library ? Object.keys(library.sets).sort() : []),
    [library],
  )

  // A filter's users: every category set with a category naming it. Used to
  // disable Delete on a filter the backend would otherwise 409 on.
  const usedByMap = useMemo(() => {
    const map: Record<string, string[]> = {}
    if (!library) return map
    for (const [setName, set] of Object.entries(library.sets)) {
      for (const cat of set.categories) {
        if (cat.filter) {
          const used = map[cat.filter] ?? (map[cat.filter] = [])
          used.push(setName)
        }
      }
    }
    return map
  }, [library])

  // Every library mutation has the same shape: write, toast the outcome, reload.
  // The rejection is re-raised so the editor card can clear its busy flag, and
  // is toasted here because the card swallows it.
  const mutate = useCallback(async (
    write: () => Promise<unknown>, success: string, failure: string,
  ) => {
    try {
      await write()
      toast.success(success)
      refetch()
    } catch (err) {
      toast.error(errorMessage(err, failure))
      throw err
    }
  }, [refetch, toast])

  const handleSaveFilter = useCallback((name: string, body: CompositionFilter) =>
    mutate(() => api.composition.saveFilter(name, body),
           `Filter "${name}" saved`, 'Failed to save filter'), [mutate])

  const handleDeleteFilter = useCallback((name: string) =>
    mutate(() => api.composition.deleteFilter(name),
           `Filter "${name}" deleted`, 'Failed to delete filter'), [mutate])

  const handleSaveSet = useCallback((name: string, body: CompositionSet) =>
    mutate(() => api.composition.saveSet(name, body),
           `Category set "${name}" saved`, 'Failed to save category set'), [mutate])

  const handleDeleteSet = useCallback((name: string) =>
    mutate(() => api.composition.deleteSet(name),
           `Category set "${name}" deleted`, 'Failed to delete category set'), [mutate])

  //## New-filter / new-set creation. NameDialog catches a rejection itself
  //## and shows it inline, so these are left to throw rather than toast.
  const handleCreateFilter = useCallback(async (newName: string) => {
    await api.composition.saveFilter(newName, { filters: [] })
    refetch()
    setShowNewFilter(false)
    toast.success(`Filter "${newName}" created`)
  }, [refetch, toast])

  const handleCreateSet = useCallback(async (newName: string) => {
    await api.composition.saveSet(newName, { label: newName, categories: [] })
    refetch()
    setShowNewSet(false)
    toast.success(`Category set "${newName}" created`)
  }, [refetch, toast])

  return (
    <>
      <div className="page-header">
        <h1>Compositions</h1>
        <p>
          Filters classify sequences by a taxonomic rule; category sets arrange filters into an
          ordered, coloured scheme (Protozoa, Fungi, Bacteria, Contaminant, and so on). Editing
          here replaces hand-editing config/composition.yml.
        </p>
      </div>

      {loading && <Skeleton lines={4} />}
      {error && <p className="error-msg">{error}</p>}

      {library && (
        <>
          <section style={{ marginBottom: 28 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
              <h2 style={{ fontSize: '1.02rem', fontWeight: 700 }}>Filters</h2>
              <button className="btn" onClick={() => setShowNewFilter(true)}>New filter</button>
            </div>

            {filterNames.length === 0 && <div className="empty-state">No filters defined.</div>}

            <div style={{ maxHeight: '60vh', overflowY: 'auto', paddingRight: 4 }}>
              {filterNames.map(fname => (
                <FilterEditor
                  key={fname}
                  name={fname}
                  filter={library.filters[fname]}
                  usedBy={usedByMap[fname] ?? []}
                  onSave={body => handleSaveFilter(fname, body)}
                  onDelete={() => handleDeleteFilter(fname)}
                />
              ))}
            </div>
          </section>

          <section>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
              <h2 style={{ fontSize: '1.02rem', fontWeight: 700 }}>Category sets</h2>
              <button className="btn" onClick={() => setShowNewSet(true)}>New set</button>
            </div>

            {setNames.length === 0 && <div className="empty-state">No category sets defined.</div>}

            <div style={{ maxHeight: '60vh', overflowY: 'auto', paddingRight: 4 }}>
              {setNames.map(sname => (
                <CategorySetEditor
                  key={sname}
                  name={sname}
                  set={library.sets[sname]}
                  filterNames={filterNames}
                  onSave={body => handleSaveSet(sname, body)}
                  onDelete={() => handleDeleteSet(sname)}
                />
              ))}
            </div>
          </section>
        </>
      )}

      {showNewFilter && (
        <NameDialog
          title="New filter"
          placeholder="Filter name"
          onConfirm={handleCreateFilter}
          onClose={() => setShowNewFilter(false)}
        />
      )}

      {showNewSet && (
        <NameDialog
          title="New category set"
          placeholder="Category-set name"
          onConfirm={handleCreateSet}
          onClose={() => setShowNewSet(false)}
        />
      )}
    </>
  )
}
