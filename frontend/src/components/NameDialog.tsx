import { useState, useRef, useEffect } from 'react'
import { errorMessage } from '../api/errorMessage'

interface Props {
  title: string
  initialValue?: string
  placeholder?: string
  onConfirm: (name: string) => Promise<void>
  onClose: () => void
}

export function NameDialog({ title, initialValue = '', placeholder = 'Name', onConfirm, onClose }: Props) {
  const [value, setValue] = useState(initialValue)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    inputRef.current?.select()
  }, [])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!value.trim()) return
    setBusy(true)
    setError('')
    try {
      await onConfirm(value.trim())
    } catch (err: unknown) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, zIndex: 1000,
        background: 'rgba(0,0,0,.45)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={e => { if (e.target === e.currentTarget) onClose() }}
    >
      <div style={{
        background: 'var(--color-bg)',
        border: '1px solid var(--color-border)',
        borderRadius: 10,
        padding: '20px 24px',
        minWidth: 320,
        boxShadow: '0 8px 32px rgba(0,0,0,.2)',
      }}>
        <h3 style={{ fontSize: '1rem', fontWeight: 700, marginBottom: 14 }}>{title}</h3>
        <form onSubmit={handleSubmit}>
          <input
            ref={inputRef}
            value={value}
            onChange={e => setValue(e.target.value)}
            onKeyDown={e => { if (e.key === 'Escape') onClose() }}
            placeholder={placeholder}
            disabled={busy}
            autoFocus
            style={{
              width: '100%',
              padding: '7px 10px',
              fontSize: '.9rem',
              border: '1px solid var(--color-border)',
              borderRadius: 6,
              background: 'var(--color-surface)',
              color: 'var(--color-fg)',
              outline: 'none',
              marginBottom: 8,
            }}
          />
          {error && (
            <p style={{ color: '#c92a2a', fontSize: '.82rem', marginBottom: 8 }}>{error}</p>
          )}
          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button type="button" className="btn" onClick={onClose} disabled={busy}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary" disabled={busy || !value.trim()}>
              {busy ? 'Saving...' : 'Save'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
