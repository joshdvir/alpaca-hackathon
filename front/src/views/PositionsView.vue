<script setup lang="ts">
import { computed, h, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { NButton, NTag } from 'naive-ui'
import { usePositionsStore } from '../stores/positions'
import Term from '../components/Term.vue'
import Pagination from '../components/Pagination.vue'

const store = usePositionsStore()
const router = useRouter()

const fmtMoney = (n: number | null | undefined) =>
  n == null ? '—' : n.toLocaleString('en-US', { style: 'currency', currency: 'USD' })
const fmtPct = (n: number | null | undefined) =>
  n == null ? '—' : `${(n * 100).toFixed(2)}%`

// Strategy-managed position detection. Anything with a non-default
// `origin` is run by a deterministic strategy (e.g. Mid-Band Movers)
// rather than the LLM. These rows carry the planned sell time +
// bucket so the user can see when the auto-close is queued.
const isStrategyManaged = (r: any) =>
  r.origin != null && r.origin !== 'default' && (r.strategy_bucket || r.planned_sell_at)

const STRATEGY_LABEL: Record<string, string> = {
  mid_band_movers: 'Mid-Band Movers',
}
const strategyLabel = (origin: string | null | undefined) =>
  origin ? (STRATEGY_LABEL[origin] || origin) : null

// Short, human-readable time for the planned_sell_at column. Renders
// in America/New_York so the displayed wall-clock time matches what
// the operator will see in their terminal / Slack notifications.
const fmtSellAt = (iso: string | null | undefined) => {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'America/New_York',
    timeZoneName: 'short'
  })
}

// Compact "MMM d, HH:mm" for the created_at / updated_at columns
// on the positions and orders tables. Same timezone as fmtSellAt
// so all wall-clock displays match.
const fmtTimestamp = (iso: string | null | undefined) => {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'America/New_York'
  })
}

// "in 1h 23m" / "in 23m" / "now" / "12m ago" — a live countdown that
// ticks every 30s so the operator can see at a glance whether a
// planned sell is imminent. Refreshes are cheap (just text) and
// re-render the whole table column.
const fmtCountdown = (iso: string | null | undefined, nowMs: number) => {
  if (!iso) return null
  const target = new Date(iso).getTime()
  if (Number.isNaN(target)) return null
  const deltaSec = Math.round((target - nowMs) / 1000)
  const abs = Math.abs(deltaSec)
  const h = Math.floor(abs / 3600)
  const m = Math.floor((abs % 3600) / 60)
  if (deltaSec > 0) {
    if (h >= 1) return `in ${h}h ${m}m`
    if (m >= 1) return `in ${m}m`
    return 'now'
  }
  return `${m}m ago`
}

// Tick every 30s so the countdown column refreshes without a full
// page reload. Cheap (one setInterval per page render); cleaned up
// on unmount so we don't leak timers when the user navigates away.
const now = ref(Date.now())
let timer: number | undefined
onMounted(() => { timer = window.setInterval(() => { now.value = Date.now() }, 30_000) })
onBeforeUnmount(() => { if (timer) window.clearInterval(timer) })

const headerWithTerm = (key: string, fallback: string) =>
  () => h(Term, { k: key, label: fallback })

// Render the Plan column. Two visual states:
//   - Strategy-managed:   bucket badge + planned sell time + countdown
//   - Default LLM-driven: "—" (so the column doesn't add noise to the
//                         rows the LLM is managing)
const planCell = (r: any) => {
  if (!isStrategyManaged(r)) {
    return h('span', { style: { color: '#999' } }, '—')
  }
  const children = []
  if (r.strategy_bucket) {
    children.push(
      h(
        NTag,
        { type: 'info', size: 'small', round: true, style: 'margin-right: 6px;' },
        { default: () => `Bucket ${r.strategy_bucket}` }
      )
    )
  }
  if (r.planned_sell_at) {
    const countdown = fmtCountdown(r.planned_sell_at, now.value)
    children.push(
      h('div', { style: { fontSize: '12px', lineHeight: '1.4' } }, [
        h('div', null, fmtSellAt(r.planned_sell_at)),
        countdown ? h('div', { style: { color: '#888' } }, countdown) : null
      ])
    )
  }
  return h('div', { style: { display: 'flex', flexDirection: 'column' } }, children)
}

// Symbol column: append a small strategy badge for strategy-managed
// positions so the user can spot them at the top of the list. The
// symbol itself is rendered as a clickable link that filters the
// table to that ticker (same intent as the symbol filter in the
// other tables — the user can clear the filter via the dropdown).
const symbolCell = (r: any) => {
  const label = strategyLabel(r.origin)
  const symbolLink = h(
    'a',
    {
      href: '#',
      style: {
        color: '#18a058',
        textDecoration: 'none',
        cursor: 'pointer'
      },
      onClick: (e: MouseEvent) => {
        e.preventDefault()
        // No symbol filter exists on the positions view (the
        // dropdown is status: open/closed/all + strategy: all/strategy).
        // Symbol filter is implicit — just alert the user that the
        // table doesn't have one. Future enhancement: route to a
        // ticker-detail view here.
        symbolClickTarget.value = r.symbol
      }
    },
    r.symbol
  )
  if (!label) return symbolLink
  return h('div', { style: { display: 'flex', alignItems: 'center', gap: '6px' } }, [
    symbolLink,
    h(
      NTag,
      { size: 'tiny', round: true, bordered: false, color: { color: '#e6f4ff', textColor: '#003a8c' } },
      { default: () => label }
    )
  ])
}

// `symbolClickTarget` holds the symbol the operator just clicked
// (so the UI can give a hint about why nothing filtered — the
// positions view doesn't have a per-symbol filter, so the click
// is a no-op beyond the visual signal).
const symbolClickTarget = ref<string | null>(null)

const columns = [
  { title: headerWithTerm('symbol', 'Symbol'), key: 'symbol', sorter: 'default', render: symbolCell },
  // Only the `updated_at` column has `defaultSortOrder: 'descend'`
  // — naive-ui's initial sort on mount. NOTE: do NOT also set
  // `sortOrder: 'descend'` here. `sortOrder` is the CONTROLLED value
  // and naive-ui calls `@update:sorter` when the user clicks a header;
  // without an `@update:sorter` handler, clicks appear to do nothing
  // (the chevron is visible but the click is silently ignored).
  // `defaultSortOrder` is the UNCONTROLLED default — naive-ui manages
  // the state internally and clicks re-sort without any handler.
  { title: headerWithTerm('qty', 'Qty'), key: 'qty', sorter: 'default' },
  { title: headerWithTerm('avg_entry_price', 'Avg Entry'), key: 'avg_entry_price', sorter: 'default', render: (r: any) => fmtMoney(r.avg_entry_price) },
  { title: headerWithTerm('market_value', 'Market Value'), key: 'market_value', sorter: 'default', render: (r: any) => fmtMoney(r.market_value) },
  { title: headerWithTerm('unrealized_pl', 'Unrealized P&L'), key: 'unrealized_pl', sorter: 'default', render: (r: any) => fmtMoney(r.unrealized_pl) },
  {
    title: headerWithTerm('unrealized_plpc', 'P&L %'),
    key: 'unrealized_plpc',
    sorter: 'default',
    render: (r: any) =>
      h(
        'span',
        { style: { color: (r.unrealized_pl ?? 0) >= 0 ? '#18a058' : '#d03050' } },
        fmtPct(r.unrealized_plpc)
      ),
  },
  // Plan column renders a custom countdown — not a sortable scalar,
  // so leave `sorter` off. Operator can still see the bucket +
  // sell time on every row.
  {
    title: headerWithTerm('plan', 'Plan'),
    key: 'plan',
    render: planCell,
  },
  { title: headerWithTerm('delta', 'Δ Delta'), key: 'delta', sorter: 'default', render: (r: any) => r.delta?.toFixed(2) ?? '—' },
  { title: headerWithTerm('theta', 'Θ Theta'), key: 'theta', sorter: 'default', render: (r: any) => r.theta?.toFixed(2) ?? '—' },
  { title: headerWithTerm('vega', 'V Vega'), key: 'vega', sorter: 'default', render: (r: any) => r.vega?.toFixed(2) ?? '—' },
  {
    title: headerWithTerm('created_at', 'Created'),
    key: 'created_at',
    width: 130,
    sorter: 'default',
    render: (r: any) => fmtTimestamp(r.created_at)
  },
  {
    title: headerWithTerm('updated_at', 'Updated'),
    key: 'updated_at',
    width: 130,
    sorter: 'default',
    defaultSortOrder: 'descend',
    render: (r: any) => fmtTimestamp(r.updated_at)
  },
  {
    title: '',
    key: 'actions',
    // Not sortable — the per-row View button is a UI affordance,
    // not data. Leaving it without a `key` for sort means naive-ui
    // doesn't show the sort chevron on this column.
    render: (r: any) =>
      h(
        NButton,
        {
          size: 'tiny',
          quaternary: true,
          onClick: () => router.push(`/positions/${r.id}`),
        },
        { default: () => 'View' }
      ),
  },
]

// Default sort: most-recently-updated first. naive-ui gates a
// column's sort on a `sorter` property (NOT on `sortable: true`,
// which is a no-op flag) — so every sortable column below uses
// `sorter: 'default'` and the `updated_at` column also carries
// `defaultSortOrder: 'descend'` for the initial sort. naive-ui's
// `n-data-table` sorts the rendered rows in-memory on the
// column's `key` (string compare for ISO 8601 timestamps works
// correctly). Operator can click any column header to re-sort.
// Fine for the page-size we load (default 25). If we move to
// server-side sort, push `sort` + `order` to the API instead.

// `status` filter re-uses the API's existing 'open' / 'closed' / 'all'
// status. `strategy` is a client-side filter that hides default-strategy
// rows so the operator can focus on the Mid-Band Movers positions
// (and any future strategy-managed ones).
const statusFilter = ref<'open' | 'closed' | 'all'>('open')
const strategyFilter = ref<'all' | 'strategy_only'>('all')

const visibleItems = computed(() => {
  if (strategyFilter.value === 'strategy_only') {
    return store.items.filter(isStrategyManaged)
  }
  return store.items
})

const strategyCount = computed(() => store.items.filter(isStrategyManaged).length)

async function refresh() {
  await store.fetchPage({ page: 1, status: statusFilter.value })
}

async function onPageChange(payload: { page: number; per_page: number }) {
  await store.fetchPage({
    page: payload.page,
    perPage: payload.per_page,
    status: statusFilter.value
  })
}

onMounted(refresh)
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / Open Positions</h1>
      <n-button @click="refresh" :loading="store.loading" size="small">Refresh</n-button>
    </div>

    <n-card style="margin-bottom: 16px;">
      <n-space align="center" :wrap="false">
        <n-select v-model:value="statusFilter" :options="[
          { label: 'Open only',  value: 'open' },
          { label: 'Closed',     value: 'closed' },
          { label: 'All',        value: 'all' }
        ]" style="width: 160px;" @update:value="refresh" />
        <n-select v-model:value="strategyFilter" :options="[
          { label: 'All positions',     value: 'all' },
          { label: 'Strategy only',     value: 'strategy_only' }
        ]" style="width: 200px;" />
        <span v-if="strategyFilter === 'strategy_only'" style="color: #888; font-size: 12px;">
          showing {{ visibleItems.length }} of {{ store.items.length }} (strategy-managed)
        </span>
        <span v-else-if="strategyCount > 0" style="color: #888; font-size: 12px;">
          {{ strategyCount }} strategy-managed in this view
        </span>
      </n-space>
    </n-card>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-card>
      <n-data-table
        :columns="columns"
        :data="visibleItems"
        :loading="store.loading"
        :bordered="false"
        :single-line="false"
        size="small"
      />
      <Pagination
        :state="{
          page: store.page,
          per_page: store.perPage,
          total: store.total,
          total_pages: store.totalPages
        }"
        :loading="store.loading"
        @change="onPageChange"
      />
    </n-card>
  </div>
</template>
