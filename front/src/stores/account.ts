import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { AccountOverview } from '../api/types'

export const useAccountStore = defineStore('account', {
  state: () => ({
    overview: null as AccountOverview | null,
    loading: false,
    refreshing: false,
    error: null as string | null,
    lastFetchedAt: null as Date | null,
  }),
  getters: {
    snapshot: (s) => s.overview?.snapshot ?? null,
    positions: (s) => s.overview?.positions ?? [],
    openOrders: (s) => s.overview?.open_orders ?? [],
    market: (s) => s.overview?.market ?? null,
    hasSnapshot: (s) => s.overview?.snapshot != null,
  },
  actions: {
    async fetch() {
      this.loading = true
      this.error = null
      try {
        this.overview = await api.get<AccountOverview>('/account')
        this.lastFetchedAt = new Date()
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    },
    // Forces the server to run AlpacaSync NOW (instead of waiting
    // for the next 30s tick). Returns whether the sync succeeded.
    async refreshNow(): Promise<boolean> {
      this.refreshing = true
      this.error = null
      try {
        await api.post<{ ok: boolean }>('/account/refresh', {})
        await this.fetch()
        return true
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
        return false
      } finally {
        this.refreshing = false
      }
    },
  },
})
