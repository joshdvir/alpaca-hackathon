<script setup lang="ts">
import { h, computed, onMounted, onUnmounted } from 'vue'
import { useDashboardStore } from '../stores/dashboard'
import { usePositionsStore } from '../stores/positions'
import { useWatchlistStore } from '../stores/watchlist'
import { useSystemStore } from '../stores/system'
import Term from '../components/Term.vue'
import AccountPanel from '../components/AccountPanel.vue'

const dashboardStore = useDashboardStore()
const positionsStore = usePositionsStore()
const watchlistStore = useWatchlistStore()
const systemStore = useSystemStore()

const fmtMoney = (n: number | null | undefined) =>
  n == null ? '—' : n.toLocaleString('en-US', { style: 'currency', currency: 'USD' })
const fmtPct = (n: number | null | undefined) =>
  n == null ? '—' : `${(n * 100).toFixed(2)}%`

async function refresh() {
  await Promise.all([
    dashboardStore.fetch(),
    positionsStore.fetchPage(),
    watchlistStore.fetchEntries(),
  ])
}

let pollHandle: number | undefined
onMounted(async () => {
  await refresh()
  // Refresh every 30s on the dashboard (the actual trading tick is 5min,
  // but the UI wants more frequent updates to feel alive)
  pollHandle = window.setInterval(refresh, 30_000)
})
onUnmounted(() => {
  if (pollHandle !== undefined) clearInterval(pollHandle)
})
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / Dashboard</h1>
      <n-button @click="refresh" :loading="dashboardStore.loading" size="small">
        Refresh
      </n-button>
    </div>

    <n-alert v-if="dashboardStore.error" type="error" :title="dashboardStore.error" closable style="margin-bottom: 16px;" />

    <AccountPanel />

    <n-grid :cols="4" :x-gap="16" :y-gap="16" responsive="screen" :item-responsive="true">
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="equity" />
          </template>
          <n-statistic :value="fmtMoney(dashboardStore.summary?.equity)" />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="cash" />
          </template>
          <n-statistic :value="fmtMoney(dashboardStore.summary?.cash)" />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="buying_power" />
          </template>
          <n-statistic :value="fmtMoney(dashboardStore.summary?.buying_power)" />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="options_buying_power" />
          </template>
          <n-statistic :value="fmtMoney(dashboardStore.summary?.options_buying_power)" />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="today_pl" />
          </template>
          <n-statistic
            :value="fmtMoney(dashboardStore.summary?.today_pl)"
            :value-style="{
              color: (dashboardStore.summary?.today_pl ?? 0) >= 0 ? '#18a058' : '#d03050'
            }"
          />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="symbol" label="Open Positions" />
          </template>
          <n-statistic :value="dashboardStore.summary?.open_positions_count ?? 0" />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>
            <Term k="watchlist" label="Active Watchlist" />
          </template>
          <n-statistic :value="dashboardStore.summary?.active_watchlist_count ?? 0" />
        </n-card>
      </n-gi>
      <n-gi :span="1">
        <n-card hoverable>
          <template #header>DB</template>
          <n-tag :type="systemStore.health?.db ? 'success' : 'warning'" size="large" round>
            {{ systemStore.health?.db ? 'connected' : 'down' }}
          </n-tag>
        </n-card>
      </n-gi>
    </n-grid>

    <n-card title="Open Positions" style="margin-top: 24px;">
      <n-data-table
        :columns="[
          { title: () => h(Term, { k: 'symbol', label: 'Symbol' }), key: 'symbol' },
          { title: () => h(Term, { k: 'qty', label: 'Qty' }), key: 'qty' },
          { title: () => h(Term, { k: 'unrealized_pl', label: 'Unrealized P&L' }), key: 'unrealized_pl', render: (r: any) => fmtMoney(r.unrealized_pl) },
          { title: () => h(Term, { k: 'unrealized_pl_pct', label: 'P&L %' }), key: 'unrealized_pl_pct', render: (r: any) => fmtPct(r.unrealized_pl_pct) }
        ]"
        :data="positionsStore.items.slice(0, 8)"
        :loading="positionsStore.loading"
        :bordered="false"
        :single-line="false"
        size="small"
      />
    </n-card>

    <n-card title="Active Watchlist (top 10)" style="margin-top: 16px;">
      <n-data-table
        :columns="[
          { title: () => h(Term, { k: 'symbol', label: 'Ticker' }), key: 'ticker' },
          { title: () => h(Term, { k: 'cycle_minutes', label: 'Cycle (min)' }), key: 'cycle_minutes' },
          { title: () => h(Term, { k: 'source', label: 'Source' }), key: 'source' }
        ]"
        :data="watchlistStore.entries.slice(0, 10)"
        :loading="watchlistStore.loading"
        :bordered="false"
        :single-line="false"
        size="small"
      />
    </n-card>
  </div>
</template>
