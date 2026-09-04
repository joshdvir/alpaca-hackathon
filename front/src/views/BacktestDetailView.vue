<script setup lang="ts">
import { h, onMounted, ref, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { NTag, NButton, NCard, NAlert, NStatistic, NDescriptions, NDescriptionsItem, NSpace, NDataTable } from 'naive-ui'
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { LineChart } from 'echarts/charts'
import { GridComponent, TooltipComponent, TitleComponent, MarkLineComponent } from 'echarts/components'
import VChart from 'vue-echarts'
import { useBacktestsStore } from '../stores/backtests'

use([CanvasRenderer, LineChart, GridComponent, TooltipComponent, TitleComponent, MarkLineComponent])

const route = useRoute()
const router = useRouter()
const store = useBacktestsStore()

const id = computed(() => Number(route.params.id))

async function refresh() {
  // One-shot fetch on mount. Live updates (BacktestRun lifecycle events)
  // come over ActionCable via useBacktestsStore; the store merges them
  // into `current` automatically, so we no longer poll.
  await store.fetchOne(id.value)
  await store.fetchTrades(id.value)
}

const isRunning = computed(() => {
  const s = store.current?.status
  return s === 'running' || s === 'pending'
})

onMounted(refresh)
watch(() => route.params.id, refresh)

// Equity curve is approximated from the per-trade log since the engine
// doesn't currently persist the full daily curve. (Each trade's pnl +
// holding window gives us an upper-bound cumulative curve.)
const equityCurve = computed(() => {
  if (!store.current) return [] as Array<{ date: string; equity: number }>
  const initial = store.current.start_of_day_equity ?? 100000
  const points: Array<{ date: string; equity: number }> = []
  let eq = initial
  points.push({ date: 'start', equity: eq })
  for (const t of store.trades) {
    eq += t.pnl ?? 0
    if (t.closed_at) points.push({ date: t.closed_at, equity: Number(eq.toFixed(2)) })
  }
  return points
})

const chartOption = computed(() => ({
  tooltip: { trigger: 'axis' as const },
  grid: { left: 50, right: 20, top: 30, bottom: 40 },
  xAxis: {
    type: 'category' as const,
    data: equityCurve.value.map((p) => p.date?.slice(0, 10) ?? ''),
    axisLabel: { rotate: 30 },
  },
  yAxis: { type: 'value' as const, scale: true },
  series: [
    {
      name: 'Equity',
      type: 'line' as const,
      data: equityCurve.value.map((p) => p.equity),
      smooth: true,
      lineStyle: { width: 2 },
      markLine: {
        symbol: 'none',
        data: [{ yAxis: store.current?.start_of_day_equity ?? 100000, label: { formatter: 'start' } }],
      },
    },
  ],
}))

function statusType(s: string) {
  return s === 'success' ? 'success'
    : s === 'error' ? 'error'
    : s === 'cancelled' ? 'default'
    : s === 'running' ? 'info'
    : 'warning'
}

const tradeColumns = [
  { title: 'ID', key: 'id', width: 60 },
  { title: 'Ticker', key: 'ticker' },
  { title: 'Strategy', key: 'strategy_type' },
  {
    title: 'Side',
    key: 'side',
    render: (t: any) => t.legs?.[0]?.side ?? '—',
  },
  {
    title: 'Symbol',
    key: 'symbol',
    render: (t: any) => t.legs?.[0]?.option_symbol ?? '—',
    ellipsis: { tooltip: true },
  },
  {
    title: 'Entry',
    key: 'entry_price',
    render: (t: any) => (t.entry_price != null ? `$${Number(t.entry_price).toFixed(2)}` : '—'),
  },
  {
    title: 'Exit',
    key: 'exit_price',
    render: (t: any) => (t.exit_price != null ? `$${Number(t.exit_price).toFixed(2)}` : '—'),
  },
  {
    title: 'P&L',
    key: 'pnl',
    render: (t: any) => {
      if (t.pnl == null) return '—'
      const n = Number(t.pnl)
      return h(NTag, { type: n >= 0 ? 'success' : 'error', size: 'small' }, {
        default: () => (n >= 0 ? `+$${n.toFixed(2)}` : `-$${Math.abs(n).toFixed(2)}`),
      })
    },
  },
  {
    title: 'Opened',
    key: 'opened_at',
    render: (t: any) => (t.opened_at ? new Date(t.opened_at).toLocaleDateString() : '—'),
  },
  {
    title: 'Closed',
    key: 'closed_at',
    render: (t: any) => (t.closed_at ? new Date(t.closed_at).toLocaleDateString() : '—'),
  },
  {
    title: 'Held (min)',
    key: 'holding_minutes',
    render: (t: any) => t.holding_minutes ?? '—',
  },
]

async function doCancel() {
  await store.cancelRun(id.value)
  await refresh()
}
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">
        Yield-paca / Backtest #{{ id }}
        <n-tag v-if="store.current" :type="statusType(store.current.status)" size="small" style="margin-left: 12px;">
          {{ store.current.status }}
        </n-tag>
      </h1>
      <n-space>
        <n-button @click="refresh" :loading="store.loading" size="small">Refresh</n-button>
        <n-button v-if="isRunning" type="warning" @click="doCancel" size="small">Cancel</n-button>
        <n-button @click="router.push({ name: 'backtests' })" size="small">Back to list</n-button>
      </n-space>
    </div>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-card v-if="store.current" style="margin-bottom: 16px;">
      <n-descriptions :column="4" bordered size="small">
        <n-descriptions-item label="Tickers">{{ store.current.tickers.join(', ') }}</n-descriptions-item>
        <n-descriptions-item label="Period">{{ store.current.period_days }} days</n-descriptions-item>
        <n-descriptions-item label="Mode">{{ store.current.mode }}</n-descriptions-item>
        <n-descriptions-item label="Workflow">{{ store.current.temporal_workflow_id || '—' }}</n-descriptions-item>
        <n-descriptions-item label="Started">{{ store.current.started_at ? new Date(store.current.started_at).toLocaleString() : '—' }}</n-descriptions-item>
        <n-descriptions-item label="Finished">{{ store.current.finished_at ? new Date(store.current.finished_at).toLocaleString() : '—' }}</n-descriptions-item>
        <n-descriptions-item label="Duration">{{ store.current.duration_seconds ? `${store.current.duration_seconds}s` : '—' }}</n-descriptions-item>
        <n-descriptions-item label="Trades">{{ store.current.total_trades }}</n-descriptions-item>
      </n-descriptions>
    </n-card>

    <n-card v-if="store.current" style="margin-bottom: 16px;">
      <n-space :size="32">
        <n-statistic label="Starting equity" :value="store.current.start_of_day_equity ?? 0" :precision="2">
          <template #prefix>$</template>
        </n-statistic>
        <n-statistic label="Final equity" :value="store.current.final_equity ?? 0" :precision="2">
          <template #prefix>$</template>
        </n-statistic>
        <n-statistic label="Total P&L" :value="(store.current.total_pnl ?? 0)">
          <template #prefix>{{ (store.current.total_pnl ?? 0) >= 0 ? '+$' : '-$' }}</template>
        </n-statistic>
        <n-statistic label="Win rate" :value="store.current.win_rate ?? 0" :precision="1">
          <template #suffix>%</template>
        </n-statistic>
        <n-statistic label="Max drawdown" :value="store.current.max_drawdown ?? 0" :precision="2">
          <template #prefix>-$</template>
        </n-statistic>
        <n-statistic label="Sharpe" :value="store.current.sharpe ?? 0" :precision="2" />
      </n-space>
    </n-card>

    <n-card v-if="store.current?.error_message" type="error" :title="store.current.error_message" style="margin-bottom: 16px;" />

    <n-card title="Equity curve (from trade log)" style="margin-bottom: 16px;">
      <v-chart v-if="equityCurve.length > 1" :option="chartOption" style="height: 360px;" autoresize />
      <n-empty v-else description="No trades yet" />
    </n-card>

    <n-card title="Trade log">
      <n-data-table
        :columns="tradeColumns"
        :data="store.trades"
        :loading="store.loading"
        :bordered="false"
        :single-line="false"
        size="small"
      />
    </n-card>
  </div>
</template>
