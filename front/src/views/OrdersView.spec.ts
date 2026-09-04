// OrdersView tests — mount with naive-ui + pinia, stub the orders
// store's paginated fetch, render sample orders, assert the table
// shows them and the pagination state matches.

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter } from 'vue-router'
import naive from 'naive-ui'
import { useOrdersStore } from '../stores/orders'
import type { Order } from '../api/types'
import OrdersView from './OrdersView.vue'

const makeOrder = (overrides: Partial<Order> = {}): Order => ({
  id: 1,
  client_order_id: 'pm-1-AAPL-1700000000',
  alpaca_order_id: 'broker-1',
  symbol: 'AAPL250117C00150000',
  side: 'buy_to_open',
  qty: 1,
  filled_qty: 0,
  filled_avg_price: null,
  type: 'limit',
  status: 'new',
  submitted_at: '2026-08-30T12:00:00Z',
  filled_at: null,
  created_at: '2026-08-30T12:00:00Z',
  ...overrides
})

const makeRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div/>' } }]
  })

const mountOrdersView = async (orders: Partial<Order>[] = []) => {
  setActivePinia(createPinia())
  const store = useOrdersStore()
  // Pre-stub the paginated fetcher so onMounted doesn't override
  // the seeded items + pagination state.
  store.fetchPage = vi.fn().mockResolvedValue(undefined)
  store.items = orders as Order[]
  store.total = orders.length
  store.page = 1
  store.perPage = 50
  store.totalPages = Math.max(1, Math.ceil(orders.length / 50))
  store.loading = false
  store.error = null
  const router = makeRouter()
  const wrapper = mount(OrdersView, { global: { plugins: [router, naive] } })
  await flushPromises()
  return { wrapper, store, router }
}

describe('OrdersView', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the page title', async () => {
    const { wrapper } = await mountOrdersView()
    expect(wrapper.text()).toContain('Yield-paca')
    expect(wrapper.text()).toContain('Orders')
  })

  it('renders one row per order', async () => {
    const orders = [
      makeOrder({ id: 1, symbol: 'AAPL250117C00150000', side: 'buy_to_open' }),
      makeOrder({ id: 2, symbol: 'TSLA260320P00200000', side: 'sell_to_open' })
    ]
    const { wrapper } = await mountOrdersView(orders)
    expect(wrapper.text()).toContain('AAPL250117C00150000')
    expect(wrapper.text()).toContain('TSLA260320P00200000')
  })

  it('calls fetchPage on mount', async () => {
    const { store } = await mountOrdersView()
    expect(store.fetchPage).toHaveBeenCalled()
  })

  it('shows the error message when the store has one', async () => {
    const { wrapper, store } = await mountOrdersView()
    store.error = 'API 500: Internal Server Error'
    await flushPromises()
    expect(wrapper.text()).toContain('API 500')
  })

  it('formats filled_avg_price as USD currency', async () => {
    const order = makeOrder({ filled_avg_price: 1.25 })
    const { wrapper } = await mountOrdersView([order])
    expect(wrapper.text()).toContain('$1.25')
  })

  it('shows "—" when filled_avg_price is null', async () => {
    const order = makeOrder({ filled_avg_price: null })
    const { wrapper } = await mountOrdersView([order])
    expect(wrapper.text()).toContain('—')
  })

  it('renders the status text inside the table', async () => {
    const orders = [
      makeOrder({ id: 1, status: 'filled' }),
      makeOrder({ id: 2, status: 'cancelled' }),
      makeOrder({ id: 3, status: 'new' })
    ]
    const { wrapper } = await mountOrdersView(orders)
    const text = wrapper.text()
    expect(text).toContain('filled')
    expect(text).toContain('cancelled')
    expect(text).toContain('new')
  })

  it('renders the Refresh button', async () => {
    const { wrapper } = await mountOrdersView()
    const buttons = wrapper.findAll('button')
    const labels = buttons.map((b) => b.text())
    expect(labels.some((t) => t.includes('Refresh'))).toBe(true)
  })

  it('clicking Refresh re-invokes fetchPage with page=1', async () => {
    const { wrapper, store } = await mountOrdersView()
    const fetchSpy = vi.spyOn(store, 'fetchPage').mockResolvedValue(undefined as any)
    const buttons = wrapper.findAll('button')
    const refreshBtn = buttons.find((b) => b.text().includes('Refresh'))!
    await refreshBtn.trigger('click')
    expect(fetchSpy).toHaveBeenCalled()
    const firstCall = fetchSpy.mock.calls[0][0]
    expect(firstCall.page).toBe(1)
  })

  it('renders the Pagination component', async () => {
    const { wrapper } = await mountOrdersView([makeOrder()])
    // Pagination renders "Showing 1–1 of 1 items" + "Page 1 of 1"
    expect(wrapper.text()).toContain('Showing')
    expect(wrapper.text()).toContain('Page')
  })

  it('clicking a symbol sets the symbol filter and re-fetches', async () => {
    // The symbol cell renders an `<a>` (styled as a link) whose
    // onClick sets `symbolFilter.value` to the row's symbol and
    // calls `refresh()`. Verify the click handler is wired so
    // operators can filter the table by ticker without retyping.
    const { wrapper, store } = await mountOrdersView([
      makeOrder({ id: 1, symbol: 'AAPL250117C00150000' }),
      makeOrder({ id: 2, symbol: 'TSLA250117C00200000' })
    ])
    const fetchSpy = vi.spyOn(store, 'fetchPage').mockResolvedValue(undefined as any)
    // The first data row's symbol cell — find the anchor with
    // the matching text.
    const link = wrapper.findAll('a').find((a) => a.text() === 'AAPL250117C00150000')!
    expect(link.exists()).toBe(true)
    await link.trigger('click')
    // refresh() should have been called with the symbol filter set.
    expect(fetchSpy).toHaveBeenCalled()
    const lastCall = fetchSpy.mock.calls[fetchSpy.mock.calls.length - 1][0]
    expect(lastCall.symbol).toBe('AAPL250117C00150000')
    // Filter input should now show the symbol.
    const input = wrapper.find('input[placeholder*="Filter by symbol"]')
    expect((input.element as HTMLInputElement).value).toBe('AAPL250117C00150000')
  })
})
