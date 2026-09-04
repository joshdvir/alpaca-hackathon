import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { AgentRun, PaginatedResponse } from '../api/types'

export interface AgentRunsState {
  items: AgentRun[]
  distinct: { agent_names: string[]; run_kinds: string[]; statuses: string[] } | null
  page: number
  perPage: number
  total: number
  totalPages: number
}

const empty: AgentRunsState = {
  items: [],
  distinct: null,
  page: 1,
  perPage: 50,
  total: 0,
  totalPages: 0
}

export interface FetchOpts {
  page?: number
  perPage?: number
  agent?: string
  ticker?: string
  status?: string
  run_kind?: string
}

export const useAgentRunsStore = defineStore('agentRuns', {
  state: (): AgentRunsState & { loading: boolean; error: string | null } => ({
    ...empty,
    loading: false,
    error: null
  }),
  actions: {
    async fetchDistinct() {
      try {
        this.distinct = await api.get('/agent_runs/distinct')
      } catch (e) {
        // Non-fatal — dropdowns fall back to model enums.
        this.error = e instanceof Error ? e.message : 'Unknown error'
      }
    },
    async fetchPage(opts: FetchOpts = {}) {
      const page = opts.page ?? this.page
      const perPage = opts.perPage ?? this.perPage
      this.loading = true
      this.error = null
      try {
        const params = new URLSearchParams()
        params.set('page', String(page))
        params.set('per_page', String(perPage))
        if (opts.agent)    params.set('agent', opts.agent)
        if (opts.ticker)   params.set('ticker', opts.ticker)
        if (opts.status)   params.set('status', opts.status)
        if (opts.run_kind) params.set('run_kind', opts.run_kind)
        const res = await api.get<PaginatedResponse<AgentRun>>(
          `/agent_runs?${params.toString()}`
        )
        this.items = res.items
        this.total = res.total
        this.page = res.page
        this.perPage = res.per_page
        this.totalPages = res.total_pages
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    }
  }
})
