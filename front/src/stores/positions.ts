import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { Position, PaginatedResponse } from '../api/types'

export interface PositionsState {
  items: Position[]
  total: number
  page: number
  perPage: number
  totalPages: number
}

const empty: PositionsState = {
  items: [],
  total: 0,
  page: 1,
  perPage: 50,
  totalPages: 0
}

export const usePositionsStore = defineStore('positions', {
  state: (): PositionsState & { loading: boolean; error: string | null } => ({
    ...empty,
    loading: false,
    error: null
  }),
  actions: {
    async fetchPage(opts: {
      page?: number
      perPage?: number
      status?: 'open' | 'closed' | 'all'
    } = {}) {
      const page = opts.page ?? this.page
      const perPage = opts.perPage ?? this.perPage
      this.loading = true
      this.error = null
      try {
        const params = new URLSearchParams()
        params.set('page', String(page))
        params.set('per_page', String(perPage))
        // Status filter: 'open' is the default (no param sent), 'closed' / 'all' override.
        if (opts.status === 'closed') params.set('status', 'closed')
        if (opts.status === 'all')  params.set('status', 'all')
        const res = await api.get<PaginatedResponse<Position>>(`/positions?${params.toString()}`)
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
