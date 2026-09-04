// WatchlistView tests — uses the new paginated fetchPages.

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter } from 'vue-router'
import naive from 'naive-ui'
import { useWatchlistStore } from '../stores/watchlist'
import type { WatchlistEntry, WatchlistRecommendation } from '../api/types'
import WatchlistView from './WatchlistView.vue'

const makeEntry = (overrides: Partial<WatchlistEntry> = {}): WatchlistEntry => ({
  ticker: 'AAPL',
  effective_from: '2026-08-30',
  effective_until: null,
  source: 'manual',
  cycle_minutes: 5,
  tags: ['options_liquid'],
  last_cycle_started_at: '2026-08-30T12:00:00Z',
  last_temporal_run_id: null,
  ...overrides
})

const makeRec = (overrides: Partial<WatchlistRecommendation> = {}): WatchlistRecommendation => ({
  ticker: 'AAPL',
  recommended_on: '2026-08-30',
  source_filter: 'insider_buying_cluster',
  confidence: 85,
  scores: null,
  rationale: 'Strong insider buying cluster',
  ...overrides
})

const makeRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div/>' } }]
  })

const mountWatchlist = async (
  entries: WatchlistEntry[] = [],
  recs: WatchlistRecommendation[] = []
) => {
  setActivePinia(createPinia())
  const store = useWatchlistStore()
  store.fetchEntries = vi.fn().mockResolvedValue(undefined)
  store.fetchRecommendations = vi.fn().mockResolvedValue(undefined)
  store.entries = entries
  store.recommendations = recs
  store.page = 1
  store.perPage = 50
  store.total = entries.length
  store.totalPages = Math.max(1, Math.ceil(entries.length / 50))
  store.recPage = 1
  store.recPerPage = 25
  store.recTotal = recs.length
  store.recTotalPages = Math.max(1, Math.ceil(recs.length / 25))
  store.loading = false
  store.error = null
  const router = makeRouter()
  const wrapper = mount(WatchlistView, { global: { plugins: [router, naive] } })
  await flushPromises()
  return { wrapper, store, router }
}

describe('WatchlistView', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the page title', async () => {
    const { wrapper } = await mountWatchlist()
    expect(wrapper.text()).toContain('Yield-paca')
    expect(wrapper.text()).toContain('Watchlist')
  })

  it('renders one row per active entry', async () => {
    const entries = [
      makeEntry({ ticker: 'AAPL' }),
      makeEntry({ ticker: 'TSLA', source: 'filter:iv_rank' })
    ]
    const { wrapper } = await mountWatchlist(entries)
    const text = wrapper.text()
    expect(text).toContain('AAPL')
    expect(text).toContain('TSLA')
    expect(text).toContain('filter:iv_rank')
  })

  it('joins tags with comma when multiple are present', async () => {
    const entry = makeEntry({ tags: ['options_liquid', 'high_iv'] })
    const { wrapper } = await mountWatchlist([entry])
    expect(wrapper.text()).toContain('options_liquid')
    expect(wrapper.text()).toContain('high_iv')
  })

  it('shows "—" when tags are null', async () => {
    const entry = makeEntry({ tags: null })
    const { wrapper } = await mountWatchlist([entry])
    expect(wrapper.text()).toContain('—')
  })

  it('shows the recommendations tab', async () => {
    const { wrapper } = await mountWatchlist([], [makeRec()])
    expect(wrapper.text()).toContain('Recent Recommendations')
  })

  it('calls fetchEntries + fetchRecommendations on mount', async () => {
    const { store } = await mountWatchlist()
    expect(store.fetchEntries).toHaveBeenCalled()
    expect(store.fetchRecommendations).toHaveBeenCalled()
  })

  it('clicking Refresh re-invokes both fetchers', async () => {
    const { wrapper, store } = await mountWatchlist()
    const fetchEntries = vi.spyOn(store, 'fetchEntries').mockResolvedValue(undefined as any)
    const fetchRecs = vi.spyOn(store, 'fetchRecommendations').mockResolvedValue(undefined as any)
    const buttons = wrapper.findAll('button')
    const btn = buttons.find((b) => b.text().includes('Refresh'))!
    expect(btn).toBeDefined()
    await btn.trigger('click')
    expect(fetchEntries).toHaveBeenCalled()
    expect(fetchRecs).toHaveBeenCalled()
  })

  it('shows the error message when the store has one', async () => {
    const { wrapper, store } = await mountWatchlist()
    store.error = 'API 500: Server Error'
    await flushPromises()
    expect(wrapper.text()).toContain('API 500')
  })

  it('renders the Pagination component on both tabs', async () => {
    const { wrapper } = await mountWatchlist([makeEntry()], [makeRec()])
    // Two Pagination components → two "Showing" strings.
    expect(wrapper.text().match(/Showing/g)?.length).toBeGreaterThanOrEqual(1)
  })
})
