<script setup lang="ts">
import { h, onMounted, ref, computed } from 'vue'
import { NTag, NInput, NInputNumber, NSelect, NSpace, NButton, NCard, NCollapse, NCollapseItem, NDataTable, NAlert, NStatistic, NDescriptions, NDescriptionsItem } from 'naive-ui'
import { useRouter } from 'vue-router'
import { useBacktestsStore } from '../stores/backtests'

const store = useBacktestsStore()
const router = useRouter()

// New run form state
const formName = ref<string>('')
const formTickers = ref<string>('')
const formPeriodDays = ref<number>(30)
const formEquity = ref<number>(100000)
const formMode = ref<'full' | 'deterministic' | 'hybrid'>('full')

const modeOptions = [
  { label: 'Full pipeline (LLM)', value: 'full' },
  { label: 'Deterministic (no LLM)', value: 'deterministic' },
  { label: 'Hybrid (LLM on day 1)', value: 'hybrid' },
]

const statusType = (s: string) =>
  s === 'success' ? 'success'
  : s === 'error' ? 'error'
  : s === 'cancelled' ? 'default'
  : s === 'running' ? 'info'
  : 'warning'

function parseTickers(): string[] {
  return formTickers.value
    .split(/[,\s]+/)
    .map((t) => t.trim().toUpperCase())
    .filter((t) => t.length > 0)
}

const canSubmit = computed(() => parseTickers().length > 0 && formPeriodDays.value > 0)

async function submit() {
  if (!canSubmit.value) return
  const result = await store.startRun({
    name: formName.value || undefined,
    tickers: parseTickers(),
    period_days: formPeriodDays.value,
    start_of_day_equity: formEquity.value,
    mode: formMode.value,
  })
  if (result) {
    router.push({ name: 'backtest-detail', params: { id: result.id } })
  }
}

const columns = [
  { title: 'ID', key: 'id', width: 60 },
  {
    title: 'Name',
    key: 'name',
    render: (r: any) => r.name || `Run #${r.id}`,
  },
  {
    title: 'Tickers',
    key: 'tickers',
    render: (r: any) => r.tickers?.join(', ') ?? '—',
    ellipsis: { tooltip: true },
  },
  { title: 'Period (days)', key: 'period_days', width: 100 },
  { title: 'Mode', key: 'mode', width: 110 },
  {
    title: 'Status',
    key: 'status',
    width: 110,
    render: (r: any) => h(NTag, { type: statusType(r.status), size: 'small' }, { default: () => r.status }),
  },
  {
    title: 'Trades',
    key: 'total_trades',
    width: 80,
    render: (r: any) => r.total_trades ?? 0,
  },
  {
    title: 'Win rate',
    key: 'win_rate',
    width: 100,
    render: (r: any) => (r.total_trades > 0 ? `${r.win_rate.toFixed(1)}%` : '—'),
  },
  {
    title: 'P&L',
    key: 'total_pnl',
    width: 110,
    render: (r: any) => {
      if (r.total_pnl == null) return '—'
      const n = Number(r.total_pnl)
      return n >= 0 ? `+$${n.toFixed(2)}` : `-$${Math.abs(n).toFixed(2)}`
    },
  },
  {
    title: 'Max DD',
    key: 'max_drawdown',
    width: 100,
    render: (r: any) => (r.max_drawdown != null ? `-$${Number(r.max_drawdown).toFixed(0)}` : '—'),
  },
  {
    title: 'Created',
    key: 'created_at',
    render: (r: any) => new Date(r.created_at).toLocaleString(),
  },
]

const rowProps = (row: any) => ({
  style: 'cursor: pointer;',
  onClick: () => router.push({ name: 'backtest-detail', params: { id: row.id } }),
})

onMounted(store.fetchAll)
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / Backtests</h1>
      <n-button @click="store.fetchAll" :loading="store.loading" size="small">Refresh</n-button>
    </div>

    <n-card title="New backtest run" style="margin-bottom: 16px;">
      <n-space vertical :size="12">
        <n-space>
          <n-input v-model:value="formName" placeholder="Name (optional)" style="width: 240px;" />
          <n-input v-model:value="formTickers" placeholder="Tickers (comma-separated, e.g. SPY, QQQ, AAPL)" style="width: 360px;" />
          <n-input-number v-model:value="formPeriodDays" :min="1" :max="365" placeholder="Period (days)" style="width: 140px;">
            <template #suffix>days</template>
          </n-input-number>
          <n-input-number v-model:value="formEquity" :min="1000" :step="1000" placeholder="Starting equity" style="width: 160px;">
            <template #prefix>$</template>
          </n-input-number>
          <n-select v-model:value="formMode" :options="modeOptions" style="width: 220px;" />
        </n-space>
        <n-space>
          <n-button type="primary" :disabled="!canSubmit" :loading="store.submitting" @click="submit">
            Start backtest
          </n-button>
          <span style="align-self: center; color: #888;">
            Pipeline runs through Temporal; the backtest history table updates as runs complete.
          </span>
        </n-space>
      </n-space>
    </n-card>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-card title="Run history">
      <n-data-table
        :columns="columns"
        :data="store.runs"
        :loading="store.loading"
        :bordered="false"
        :single-line="false"
        :row-props="rowProps"
        size="small"
      />
    </n-card>
  </div>
</template>
