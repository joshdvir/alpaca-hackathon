import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { ResearchSummary } from '../api/types'

export const useResearchStore = defineStore('research', {
  state: () => ({
    summary: null as ResearchSummary | null,
    loading: false,
    error: null as string | null,
    lastFetchedAt: null as Date | null,
  }),
  actions: {
    async fetch(ticker?: string) {
      this.loading = true
      this.error = null
      try {
        const q = ticker ? `?ticker=${encodeURIComponent(ticker)}` : ''
        this.summary = await api.get<ResearchSummary>(`/research${q}`)
        this.lastFetchedAt = new Date()
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    },
  },
})
