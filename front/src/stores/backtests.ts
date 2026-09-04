import { defineStore } from 'pinia'
import { ref, computed, onScopeDispose } from 'vue'
import { api } from '../api/client'
import { liveUpdates, type LiveEvent } from '../api/liveUpdates'
import type { BacktestRun, BacktestRunStatus, BacktestTrade, CreateBacktestInput } from '../api/types'

export const useBacktestsStore = defineStore('backtests', () => {
  const runs = ref<BacktestRun[]>([])
  const current = ref<BacktestRun | null>(null)
  const trades = ref<BacktestTrade[]>([])
  const status = ref<BacktestRunStatus | null>(null)
  const loading = ref(false)
  const submitting = ref(false)
  const error = ref<string | null>(null)

  const activeRuns = computed(() =>
    runs.value.filter((r) => r.status === 'running' || r.status === 'pending')
  )

  // ---- Live updates ----
  // Merge incoming BacktestRun updates into `runs` and `current` so the UI
  // re-renders without a manual refresh. We still call fetchOne() for the
  // initial paint of a detail view; subsequent changes ride the socket.
  const unsubscribe = liveUpdates.subscribe('backtests', (ev: LiveEvent) => {
    const rec = (ev.record || {}) as Partial<BacktestRun> & { id?: number }
    if (!rec.id) return
    const idx = runs.value.findIndex((r) => r.id === rec.id)
    if (ev.event === 'destroyed') {
      if (idx >= 0) runs.value.splice(idx, 1)
      if (current.value?.id === rec.id) current.value = null
      return
    }
    if (idx >= 0) runs.value[idx] = { ...runs.value[idx], ...rec } as BacktestRun
    else if (rec.id) runs.value.unshift(rec as BacktestRun)
    if (current.value?.id === rec.id) {
      current.value = { ...current.value, ...rec } as BacktestRun
      // status view polls this on its own; mirror it here for free.
      status.value = {
        id: current.value.id,
        status: current.value.status,
        total_trades: current.value.total_trades,
        total_pnl: current.value.total_pnl,
        final_equity: current.value.final_equity,
        started_at: current.value.started_at,
        finished_at: current.value.finished_at,
        error_message: current.value.error_message
      }
    }
  })
  onScopeDispose(() => unsubscribe())

  // ---- REST actions (initial paint, mutations) ----

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      // The /api/backtests endpoint returns a paginated response
      // ({items, total, page, per_page, total_pages}). We read .items
      // and tolerate the older bare-array response too.
      const response = await api.get<BacktestRun[] | { items: BacktestRun[] }>('/backtests')
      runs.value = Array.isArray(response) ? response : (response?.items ?? [])
    } catch (e) {
      error.value = (e as Error).message
    } finally {
      loading.value = false
    }
  }

  async function fetchOne(id: number) {
    loading.value = true
    error.value = null
    try {
      current.value = await api.get<BacktestRun>(`/backtests/${id}`)
    } catch (e) {
      error.value = (e as Error).message
    } finally {
      loading.value = false
    }
  }

  async function fetchTrades(id: number) {
    try {
      trades.value = await api.get<BacktestTrade[]>(`/backtests/${id}/trades`)
    } catch (e) {
      error.value = (e as Error).message
    }
  }

  async function fetchStatus(id: number) {
    try {
      status.value = await api.get<BacktestRunStatus>(`/backtests/${id}/status`)
    } catch (e) {
      error.value = (e as Error).message
    }
  }

  async function startRun(input: CreateBacktestInput): Promise<BacktestRun | null> {
    submitting.value = true
    error.value = null
    try {
      const created = await api.post<BacktestRun>('/backtests', input)
      runs.value = [created, ...runs.value]
      return created
    } catch (e) {
      error.value = (e as Error).message
      return null
    } finally {
      submitting.value = false
    }
  }

  async function cancelRun(id: number) {
    try {
      await api.post<BacktestRunStatus>(`/backtests/${id}/cancel`, {})
      // The cancel handler in the API will mark the run as `cancelled`
      // and the backtest workflow will exit; the next :backtests event
      // will refresh the row.
    } catch (e) {
      error.value = (e as Error).message
    }
  }

  return {
    runs,
    current,
    trades,
    status,
    loading,
    submitting,
    error,
    activeRuns,
    fetchAll,
    fetchOne,
    fetchTrades,
    fetchStatus,
    startRun,
    cancelRun,
  }
})
