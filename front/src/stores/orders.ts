import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { Order, PaginatedResponse } from '../api/types'

// Single page of orders + the current pagination state. The view
// listens for `change` events from the Pagination component and
// calls `fetchPage` with the new page/per_page.
export interface OrdersState {
  items: Order[]
  total: number
  page: number
  perPage: number
  totalPages: number
}

const empty: OrdersState = {
  items: [],
  total: 0,
  page: 1,
  perPage: 50,
  totalPages: 0
}

export const useOrdersStore = defineStore('orders', {
  state: (): OrdersState & { loading: boolean; error: string | null } => ({
    ...empty,
    loading: false,
    error: null
  }),
  actions: {
    async fetchPage(opts: {
      page?: number
      perPage?: number
      symbol?: string
      status?: string
    } = {}) {
      const page = opts.page ?? this.page
      const perPage = opts.perPage ?? this.perPage
      this.loading = true
      this.error = null
      try {
        const params = new URLSearchParams()
        params.set('page', String(page))
        params.set('per_page', String(perPage))
        if (opts.symbol) params.set('symbol', opts.symbol)
        if (opts.status) params.set('status', opts.status)
        const res = await api.get<PaginatedResponse<Order>>(`/orders?${params.toString()}`)
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
