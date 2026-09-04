// AgentRunsView tests — verify the new paginated fetch flow.

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter } from 'vue-router'
import naive from 'naive-ui'
import { useAgentRunsStore } from '../stores/agentRuns'
import type { AgentRun } from '../api/types'
import AgentRunsView from './AgentRunsView.vue'

const makeRun = (overrides: Partial<AgentRun> = {}): AgentRun => ({
  id: 1,
  agent_name: 'Debate::ResearchManager',
  run_kind: 'research',
  ticker: 'AAPL',
  status: 'success',
  rationale: 'test',
  model_used: 'test-model',
  input_tokens: 100,
  output_tokens: 50,
  duration_ms: 1000,
  error_message: null,
  temporal_workflow_id: 'wf-1',
  created_at: '2026-08-30T12:00:00Z',
  ...overrides
})

const makeRouter = () =>
  createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div/>' } }]
  })

const mountAgentRuns = async (runs: AgentRun[] = []) => {
  setActivePinia(createPinia())
  const store = useAgentRunsStore()
  store.fetchPage = vi.fn().mockResolvedValue(undefined)
  store.fetchDistinct = vi.fn().mockResolvedValue(undefined)
  store.items = runs
  store.distinct = { agent_names: ['Debate::ResearchManager'], run_kinds: ['research'], statuses: ['success'] }
  store.page = 1
  store.perPage = 50
  store.total = runs.length
  store.totalPages = Math.max(1, Math.ceil(runs.length / 50))
  store.loading = false
  store.error = null
  const router = makeRouter()
  const wrapper = mount(AgentRunsView, { global: { plugins: [router, naive] } })
  await flushPromises()
  return { wrapper, store, router }
}

describe('AgentRunsView', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the page title', async () => {
    const { wrapper } = await mountAgentRuns()
    expect(wrapper.text()).toContain('Yield-paca')
    expect(wrapper.text()).toContain('Agent Runs')
  })

  it('renders one row per agent run', async () => {
    const runs = [
      makeRun({ id: 1, agent_name: 'Analyst::MarketDataAnalyst' }),
      makeRun({ id: 2, agent_name: 'Trader' })
    ]
    const { wrapper } = await mountAgentRuns(runs)
    expect(wrapper.text()).toContain('Analyst::MarketDataAnalyst')
    expect(wrapper.text()).toContain('Trader')
  })

  it('calls fetchDistinct + fetchPage on mount', async () => {
    const { store } = await mountAgentRuns()
    expect(store.fetchDistinct).toHaveBeenCalled()
    expect(store.fetchPage).toHaveBeenCalled()
  })

  it('clicking Refresh re-invokes fetchPage with page=1', async () => {
    const { wrapper, store } = await mountAgentRuns()
    const fetchSpy = vi.spyOn(store, 'fetchPage').mockResolvedValue(undefined as any)
    const buttons = wrapper.findAll('button')
    const refreshBtn = buttons.find((b) => b.text().includes('Refresh'))!
    await refreshBtn.trigger('click')
    expect(fetchSpy).toHaveBeenCalled()
    expect(fetchSpy.mock.calls[0][0].page).toBe(1)
  })

  it('shows the error message when the store has one', async () => {
    const { wrapper, store } = await mountAgentRuns()
    store.error = 'API 500: Server Error'
    await flushPromises()
    expect(wrapper.text()).toContain('API 500')
  })

  it('renders the Pagination component', async () => {
    const { wrapper } = await mountAgentRuns([makeRun()])
    expect(wrapper.text()).toContain('Showing')
    expect(wrapper.text()).toContain('Page')
  })
})
