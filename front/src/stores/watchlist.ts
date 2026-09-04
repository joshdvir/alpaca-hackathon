import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { WatchlistEntry, WatchlistRecommendation, PaginatedResponse } from '../api/types'

export interface WatchlistState {
  entries: WatchlistEntry[]
  recommendations: WatchlistRecommendation[]
  // Pagination state for the entries table
  page: number
  perPage: number
  total: number
  totalPages: number
  // Pagination state for the recommendations table
  recPage: number
  recPerPage: number
  recTotal: number
  recTotalPages: number
}

const empty: WatchlistState = {
  entries: [],
  recommendations: [],
  page: 1,
  perPage: 50,
  total: 0,
  totalPages: 0,
  recPage: 1,
  recPerPage: 25,
  recTotal: 0,
  recTotalPages: 0
}

export const useWatchlistStore = defineStore('watchlist', {
  state: (): WatchlistState & { loading: boolean; error: string | null } => ({
    ...empty,
    loading: false,
    error: null
  }),
  actions: {
    async fetchEntries(opts: { page?: number; perPage?: number; ticker?: string } = {}) {
      const page = opts.page ?? this.page
      const perPage = opts.perPage ?? this.perPage
      this.loading = true
      this.error = null
      try {
        const params = new URLSearchParams()
        params.set('page', String(page))
        params.set('per_page', String(perPage))
        if (opts.ticker) params.set('ticker', opts.ticker)
        const res = await api.get<PaginatedResponse<WatchlistEntry>>(`/watchlist?${params.toString()}`)
        this.entries = res.items
        this.total = res.total
        this.page = res.page
        this.perPage = res.per_page
        this.totalPages = res.total_pages
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    },
    async fetchRecommendations(opts: { page?: number; perPage?: number; ticker?: string; filter?: string } = {}) {
      const page = opts.page ?? this.recPage
      const perPage = opts.perPage ?? this.recPerPage
      this.loading = true
      this.error = null
      try {
        const params = new URLSearchParams()
        params.set('page', String(page))
        params.set('per_page', String(perPage))
        if (opts.ticker) params.set('ticker', opts.ticker)
        if (opts.filter) params.set('filter', opts.filter)
        const res = await api.get<PaginatedResponse<WatchlistRecommendation>>(
          `/watchlist/recommendations?${params.toString()}`
        )
        this.recommendations = res.items
        this.recTotal = res.total
        this.recPage = res.page
        this.recPerPage = res.per_page
        this.recTotalPages = res.total_pages
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    }
  }
})
