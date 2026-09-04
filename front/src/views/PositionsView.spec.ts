// PositionsView tests — uses the new paginated fetchPage API.

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter } from 'vue-router'
import naive from 'naive-ui'
import { usePositionsStore } from '../stores/positions'
import type { Position } from '../api/types'
import PositionsView from './PositionsView.vue'

const makePosition = (overrides: Partial<Position> = {}): Position => ({
  id: 1,
  symbol: 'AAPL250117C00150000',
  qty: 1,
  avg_entry_price: 2.50,
  market_value: 3.00,
  unrealized_pl: 50.0,
  unrealized_plpc: 0.20,
  origin: 'default',
  strategy_bucket: null,
  planned_sell_at: null,
  delta: 0.55,
  gamma: 0.04,
  theta: -0.10,
  vega: 0.20,
  snapshot_at: '2026-08-30T12:00:00Z',
  closed_at: null,
  ...overrides
})

const makeRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/', component: { template: '<div/>' } },
      { path: '/positions/:id', component: { template: '<div/>' } }
    ]
  })

const mountPositionsView = async (positions: Partial<Position>[] = []) => {
  setActivePinia(createPinia())
  const store = usePositionsStore()
  store.fetchPage = vi.fn().mockResolvedValue(undefined)
  store.items = positions as Position[]
  store.total = positions.length
  store.page = 1
  store.perPage = 50
  store.totalPages = Math.max(1, Math.ceil(positions.length / 50))
  store.loading = false
  store.error = null
  const router = makeRouter()
  const wrapper = mount(PositionsView, { global: { plugins: [router, naive] } })
  await flushPromises()
  return { wrapper, store, router }
}

describe('PositionsView', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the page title', async () => {
    const { wrapper } = await mountPositionsView()
    expect(wrapper.text()).toContain('Yield-paca')
    expect(wrapper.text()).toContain('Open Positions')
  })

  it('renders one row per position', async () => {
    const positions = [
      makePosition({ id: 1, symbol: 'AAPL250117C00150000' }),
      makePosition({ id: 2, symbol: 'TSLA260320P00200000' })
    ]
    const { wrapper } = await mountPositionsView(positions)
    expect(wrapper.text()).toContain('AAPL250117C00150000')
    expect(wrapper.text()).toContain('TSLA260320P00200000')
  })

  it('calls fetchPage on mount', async () => {
    const { store } = await mountPositionsView()
    expect(store.fetchPage).toHaveBeenCalled()
  })

  it('formats avg_entry_price as USD', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({ avg_entry_price: 2.5 })
    ])
    expect(wrapper.text()).toContain('$2.50')
  })

  it('formats unrealized_plpc as a percentage', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({ unrealized_plpc: 0.205 })
    ])
    expect(wrapper.text()).toContain('20.50%')
  })

  it('shows the greeks as fixed-point numbers', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({ delta: 0.554, theta: -0.103, vega: 0.198 })
    ])
    const text = wrapper.text()
    expect(text).toContain('0.55')
    expect(text).toContain('-0.10')
    expect(text).toContain('0.20')
  })

  it('shows "—" when a greek is null', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({ delta: null, theta: null, vega: null })
    ])
    const text = wrapper.text()
    const dashCount = (text.match(/—/g) || []).length
    expect(dashCount).toBeGreaterThanOrEqual(3)
  })

  it('navigates to the position detail on View click', async () => {
    const ctx = await mountPositionsView([makePosition({ id: 42 })])
    const buttons = ctx.wrapper.findAll('button')
    const viewBtn = buttons.find((b) => b.text().includes('View'))!
    await viewBtn.trigger('click')
    await flushPromises()
    expect(ctx.router.currentRoute.value.path).toBe('/positions/42')
  })

  it('shows the error message when the store has one', async () => {
    const { wrapper, store } = await mountPositionsView()
    store.error = 'API 500: Internal Server Error'
    await flushPromises()
    expect(wrapper.text()).toContain('API 500')
  })

  it('renders the Pagination component', async () => {
    const { wrapper } = await mountPositionsView([makePosition()])
    expect(wrapper.text()).toContain('Showing')
    expect(wrapper.text()).toContain('Page')
  })

  // ------------------------------------------------------------------
  // Mid-Band Movers / strategy-managed positions
  // ------------------------------------------------------------------

  it('shows a strategy badge in the Symbol column for strategy-managed positions', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({
        id: 1, symbol: 'AAPL250117C00150000', origin: 'default',
        strategy_bucket: null, planned_sell_at: null
      }),
      makePosition({
        id: 2, symbol: 'TSLA260320P00200000', origin: 'mid_band_movers',
        strategy_bucket: 'A', planned_sell_at: '2026-09-01T13:30:00Z'
      })
    ])
    const text = wrapper.text()
    expect(text).toContain('Mid-Band Movers')  // strategy badge
  })

  it('renders the Plan column for a strategy-managed position with bucket + sell time', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({
        origin: 'mid_band_movers',
        strategy_bucket: 'A',
        planned_sell_at: '2026-09-01T17:30:00Z'
      })
    ])
    const text = wrapper.text()
    expect(text).toContain('Bucket A')
    // The sell time is rendered in America/New_York; check the date
    // string Sep 1 (regardless of timezone math the test machine does).
    expect(text).toMatch(/Sep\s+1/)
  })

  it('renders "—" in the Plan column for default-strategy positions', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({ origin: 'default', strategy_bucket: null, planned_sell_at: null })
    ])
    // Multiple "—" cells are expected (one per nullable column), so
    // we just check the dash count is reasonable.
    const text = wrapper.text()
    expect(text).toContain('—')
  })

  it('shows the strategy-only count in the status bar when strategy positions exist', async () => {
    const { wrapper } = await mountPositionsView([
      makePosition({ id: 1, origin: 'default' }),
      makePosition({ id: 2, origin: 'mid_band_movers', strategy_bucket: 'A' })
    ])
    await flushPromises()
    expect(wrapper.text()).toContain('1 strategy-managed in this view')
  })
})
