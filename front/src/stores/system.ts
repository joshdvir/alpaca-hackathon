import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { SystemHealth, RateLimitStats } from '../api/types'

export const useSystemStore = defineStore('system', {
  state: () => ({
    health: null as SystemHealth | null,
    rateLimits: null as RateLimitStats | null,
    loading: false,
    error: null as string | null,
    lastFetchedAt: null as Date | null,
  }),
  actions: {
    async fetchHealth() {
      this.error = null
      try {
        this.health = await api.get<SystemHealth>('/system/health')
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.lastFetchedAt = new Date()
      }
    },
    async fetchRateLimits(window: '1h' | '24h' | '7d' = '1h') {
      try {
        this.rateLimits = await api.get<RateLimitStats>(
          `/rate_limits/stats?window=${window}`
        )
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      }
    },
  },
})
