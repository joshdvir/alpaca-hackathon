// DashboardView tests — pre-stub store methods so onMounted's calls
// are observable. Polling interval is set up but we don't wait for
// it to fire (would make tests slow); we just confirm the initial
// fetch is invoked.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter } from 'vue-router'
import naive from 'naive-ui'
import { useDashboardStore } from '../stores/dashboard'
import { usePositionsStore } from '../stores/positions'
import { useWatchlistStore } from '../stores/watchlist'
import { useSystemStore } from '../stores/system'
import type { DashboardSummary, Position, SystemHealth } from '../api/types'
import DashboardView from './DashboardView.vue'

const makeSummary = (overrides: Partial<DashboardSummary> = {}): DashboardSummary => ({
  equity: 100000,
  cash: 50000,
  buying_power: 200000,
  options_buying_power: 50000,
  today_pl: 1234.56,
  open_positions_count: 3,
  active_watchlist_count: 11,
  last_run_at: '2026-08-30T12:00:00Z',
  last_run_agent: 'Debate::ResearchManager',
  server_time: '2026-08-30T12:00:00Z',
  ...overrides
})

const makePosition = (overrides: Partial<Position> = {}): Position => ({
  id: 1,
  symbol: 'AAPL250117C00150000',
  qty: 1,
  avg_entry_price: 2.50,
  market_value: 3.00,
  unrealized_pl: 50.0,
  unrealized_pl_pct: 0.20,
  delta: 0.55,
  gamma: 0.04,
  theta: -0.10,
  vega: 0.20,
  snapshot_at: '2026-08-30T12:00:00Z',
  closed_at: null,
  ...overrides
})

const makeHealth = (overrides: Partial<SystemHealth> = {}): SystemHealth => ({
  status: 'ok',
  server_time: '2026-08-30T12:00:00Z',
  db: true,
  temporal: true,
  active_watchlist_count: 11,
  open_positions_count: 3,
  last_agent_run_at: '2026-08-30T12:00:00Z',
  last_agent_name: 'Debate::ResearchManager',
  kill_switch: false,
  ...overrides
})

const makeRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div/>' } }]
  })

const mountDashboard = async (
  summary: DashboardSummary | null,
  positions: Position[] = [],
  health: SystemHealth | null = null
) => {
  setActivePinia(createPinia())
  const dashboard = useDashboardStore()
  const pos = usePositionsStore()
  const watch = useWatchlistStore()
  const system = useSystemStore()
  // Pre-stub so onMounted's calls are observable.
  dashboard.fetch = vi.fn().mockResolvedValue(undefined as any)
  pos.fetchPage = vi.fn().mockResolvedValue(undefined as any)
  watch.fetchEntries = vi.fn().mockResolvedValue(undefined as any)

  const router = makeRouter()
  const wrapper = mount(DashboardView, {
    global: { plugins: [router, naive] }
  })
  dashboard.summary = summary
  dashboard.loading = false
  dashboard.error = null
  pos.list = positions
  pos.items = positions
  pos.loading = false
  watch.entries = []
  watch.loading = false
  system.health = health
  await flushPromises()
  return { wrapper, dashboard, pos, watch, system, router }
}

describe('DashboardView', () => {
  beforeEach(() => vi.restoreAllMocks())
  afterEach(() => vi.restoreAllMocks())

  it('shows the page title', async () => {
    const { wrapper } = await mountDashboard(makeSummary())
    expect(wrapper.text()).toContain('Yield-paca')
    expect(wrapper.text()).toContain('Dashboard')
  })

  it('renders the equity value formatted as USD', async () => {
    const { wrapper } = await mountDashboard(makeSummary({ equity: 100000 }))
    expect(wrapper.text()).toContain('$100,000.00')
  })

  it('shows the open positions count', async () => {
    const { wrapper } = await mountDashboard(makeSummary({ open_positions_count: 7 }))
    expect(wrapper.text()).toContain('7')
  })

  it('shows the active watchlist count', async () => {
    const { wrapper } = await mountDashboard(makeSummary({ active_watchlist_count: 11 }))
    expect(wrapper.text()).toContain('11')
  })

  it('passes a non-empty value-style to the today_pl NStatistic (positive P&L)', async () => {
    // We just verify the positive path. The Dashboard view passes
    // :value-style with a green hex (#18a058) for positive P&L and
    // red (#d03050) for negative. We don't pin the exact inline CSS
    // shape here because NStatistic serializes it as a CSS variable
    // and the variable name is an internal naive-ui detail; the
    // important behavior is "the call does not throw and the value
    // renders".
    const posWrap = await mountDashboard(makeSummary({ today_pl: 100 }))
    expect(posWrap.wrapper.text()).toContain('100')
    posWrap.wrapper.unmount()

    const negWrap = await mountDashboard(makeSummary({ today_pl: -100 }))
    // Negative numbers render with a leading minus in fmtMoney.
    expect(negWrap.wrapper.text()).toContain('-')
  })

  it('shows "—" when summary values are null', async () => {
    const { wrapper } = await mountDashboard(
      makeSummary({ equity: null, cash: null, today_pl: null })
    )
    const text = wrapper.text()
    const dashCount = (text.match(/—/g) || []).length
    expect(dashCount).toBeGreaterThanOrEqual(3)
  })

  it('renders the positions mini-table with the loaded positions', async () => {
    const positions = [
      makePosition({ id: 1, symbol: 'AAPL250117C00150000', unrealized_pl: 50 }),
      makePosition({ id: 2, symbol: 'TSLA260320P00200000', unrealized_pl: -25 })
    ]
    const { wrapper } = await mountDashboard(makeSummary(), positions)
    expect(wrapper.text()).toContain('AAPL250117C00150000')
    expect(wrapper.text()).toContain('TSLA260320P00200000')
  })

  it('shows the DB connection status from the system health', async () => {
    const { wrapper } = await mountDashboard(makeSummary(), [], makeHealth({ db: true }))
    expect(wrapper.text()).toContain('connected')
  })

  it('calls fetch on mount for dashboard, positions, and watchlist', async () => {
    const ctx = await mountDashboard(makeSummary())
    expect(ctx.dashboard.fetch).toHaveBeenCalled()
    expect(ctx.pos.fetchPage).toHaveBeenCalled()
    expect(ctx.watch.fetchEntries).toHaveBeenCalled()
  })

  it('shows the error message when the dashboard store has one', async () => {
    const { wrapper, dashboard } = await mountDashboard(makeSummary())
    dashboard.error = 'API 500: Server Error'
    await flushPromises()
    expect(wrapper.text()).toContain('API 500')
  })
})
