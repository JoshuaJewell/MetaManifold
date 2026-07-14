import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { ToastProvider } from './components/Toast'
import { Layout } from './layout/Layout'
import { StudiesView } from './views/StudiesView'
import { StudyView } from './views/StudyView'
import { RunView } from './views/RunView'
import { SlugResolver } from './views/SlugResolver'
import { JobsView } from './views/JobsView'
import { DatabasesView } from './views/DatabasesView'
import { NotFoundView } from './views/NotFoundView'
import { DefaultConfigView } from './views/DefaultConfigView'
import { CompositionsView } from './views/CompositionsView'

export function App() {
  return (
    <ToastProvider>
      <BrowserRouter>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<Navigate to="/studies" replace />} />
            <Route path="studies" element={<StudiesView />} />
            <Route path="jobs" element={<JobsView />} />
            <Route path="databases" element={<DatabasesView />} />
            <Route path="config" element={<DefaultConfigView />} />
            <Route path="compositions" element={<CompositionsView />} />
            <Route path=":study" element={<StudyView />} />
            <Route path=":study/:slug" element={<SlugResolver />} />
            <Route path=":study/:group/:run" element={<RunView />} />
            <Route path="*" element={<NotFoundView />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </ToastProvider>
  )
}
