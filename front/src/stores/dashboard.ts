import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { DashboardSummary } from '../api/types'

export const useDashboardStore = defineStore('dashboard', {
  state: () => ({
    summary: null as DashboardSummary | null,
    loading: false,
    error: null as string | null,
    lastFetchedAt: null as Date | null,
  }),
  actions: {
    async fetch() {
      this.loading = true
      this.error = null
      try {
        this.summary = await api.get<DashboardSummary>('/dashboard')
        this.lastFetchedAt = new Date()
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    },
  },
})
