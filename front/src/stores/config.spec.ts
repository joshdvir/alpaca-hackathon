// Config store tests — covers the dirty-state tracking, save
// success/failure, and the remote-reload behavior that prevents the
// front-end from blowing away the user's local edits when the
// server-side file changes.

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useConfigStore } from './config'
import { api } from '../api/client'

// Mock the api client so we don't hit the network.
vi.mock('../api/client', () => ({
  api: {
    get: vi.fn(),
    patch: vi.fn()
  }
}))

const mockSnapshot = (overrides: Partial<{
  config: Record<string, unknown>
  raw_yaml: string
  loaded_from: string
  loaded_at: string
}> = {}) => ({
  config: { risk_limits: { max_open_positions: 3 } },
  raw_yaml: "risk_limits:\n  max_open_positions: 3\n",
  loaded_from: '/app/config/trading.yml',
  loaded_at: '2026-08-30T06:00:00Z',
  ...overrides
})

const mockSaveResponse = (overrides: Partial<{
  ok: boolean
  config: Record<string, unknown>
  loaded_from: string
  loaded_at: string
}> = {}) => ({
  ok: true,
  config: { risk_limits: { max_open_positions: 7 } },
  loaded_from: '/app/config/trading.yml',
  loaded_at: '2026-08-30T06:01:00Z',
  ...overrides
})

describe('config store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('fetches the snapshot and initializes the draft', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    const store = useConfigStore()
    await store.fetch()
    expect(store.config?.raw_yaml).toBe("risk_limits:\n  max_open_positions: 3\n")
    expect(store.draft).toBe(store.config?.raw_yaml)
    expect(store.isDirty).toBe(false)
    expect(store.error).toBeNull()
  })

  it('captures fetch errors in state', async () => {
    vi.mocked(api.get).mockRejectedValue(new Error('API 500'))
    const store = useConfigStore()
    await store.fetch()
    expect(store.error).toBe('API 500')
  })

  it('marks the draft as dirty when the user edits', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    const store = useConfigStore()
    await store.fetch()
    store.setDraft("risk_limits:\n  max_open_positions: 9\n")
    expect(store.isDirty).toBe(true)
  })

  it('save() calls PATCH and clears the dirty flag', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    vi.mocked(api.patch).mockResolvedValue(mockSaveResponse())
    const store = useConfigStore()
    await store.fetch()
    store.setDraft("risk_limits:\n  max_open_positions: 7\n")
    await store.save()
    expect(api.patch).toHaveBeenCalledWith('/config', { raw_yaml: store.draft })
    expect(store.isDirty).toBe(false)
    expect(store.lastSavedAt).toBe('2026-08-30T06:01:00Z')
  })

  it('save() re-throws on server error so the caller can show a notification', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    vi.mocked(api.patch).mockRejectedValue(new Error('YAML syntax error'))
    const store = useConfigStore()
    await store.fetch()
    store.setDraft("garbage: : :")
    await expect(store.save()).rejects.toThrow('YAML syntax error')
    expect(store.error).toBe('YAML syntax error')
  })

  it('onRemoteReload updates config + lastSavedAt but keeps the dirty draft', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    const store = useConfigStore()
    await store.fetch()
    store.setDraft("risk_limits:\n  max_open_positions: 9\n")
    expect(store.isDirty).toBe(true)

    const remote = mockSnapshot({ raw_yaml: "risk_limits:\n  max_open_positions: 11\n" })
    await store.onRemoteReload(remote)
    expect(store.lastSavedAt).toBe(remote.loaded_at)
    // The draft is preserved so the user doesn't lose their work.
    expect(store.draft).toBe("risk_limits:\n  max_open_positions: 9\n")
    expect(store.isDirty).toBe(true)
  })

  it('onRemoteReload replaces the draft when the user has no unsaved edits', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    const store = useConfigStore()
    await store.fetch()
    // draft equals the server snapshot, so isDirty is false.
    const remote = mockSnapshot({ raw_yaml: "fresh: 1\n" })
    await store.onRemoteReload(remote)
    expect(store.draft).toBe("fresh: 1\n")
    expect(store.isDirty).toBe(false)
  })

  it('discard() reloads the draft from the server snapshot', async () => {
    vi.mocked(api.get).mockResolvedValue(mockSnapshot())
    const store = useConfigStore()
    await store.fetch()
    store.setDraft("modified: true\n")
    expect(store.isDirty).toBe(true)
    await store.discard()
    expect(store.draft).toBe(store.config?.raw_yaml)
    expect(store.isDirty).toBe(false)
  })
})
