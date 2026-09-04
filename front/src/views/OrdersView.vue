<script setup lang="ts">
import { h, onMounted, ref } from 'vue'
import { NTag } from 'naive-ui'
import { useOrdersStore } from '../stores/orders'
import Term from '../components/Term.vue'
import Pagination from '../components/Pagination.vue'

const store = useOrdersStore()

const fmtMoney = (n: number | null | undefined) =>
  n == null ? '—' : n.toLocaleString('en-US', { style: 'currency', currency: 'USD' })

// Compact "MMM d, HH:mm" for the created_at / updated_at columns.
// Renders in America/New_York so the wall-clock matches what the
// operator sees in their terminal and Slack notifications.
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

const statusType = (s: string) => {
  if (s === 'filled') return 'success'
  if (s === 'cancelled' || s === 'expired') return 'error'
  if (s === 'new' || s === 'partial') return 'warning'
  return 'default'
}

const headerWithTerm = (key: string, fallback: string) =>
  () => h(Term, { k: key, label: fallback })

const columns = [
  {
    title: headerWithTerm('symbol', 'Symbol'),
    key: 'symbol',
    sorter: 'default',
    // Clicking a symbol sets the symbol filter so the table
    // narrows to that ticker. The filter input above the table
    // is the source of truth, so this just dispatches the
    // 'filter by this symbol' intent the same way typing in the
    // input would.
    render: (r: any) =>
      h(
        'a',
        {
          href: '#',
          // Cursor: pointer so the user gets a clear clickable
          // affordance. Underline on hover so the link "lights up"
          // when the operator is about to click it.
          style: {
            color: '#18a058',
            textDecoration: 'none',
            cursor: 'pointer'
          },
          // Stop the browser from following the href (which would
          // scroll to the top of the page) so the SPA state stays
          // intact.
          onClick: (e: MouseEvent) => {
            e.preventDefault()
            symbolFilter.value = r.symbol
            refresh()
          }
        },
        r.symbol
      )
  },
  {
    title: headerWithTerm('side', 'Side'),
    key: 'side',
    sorter: 'default',
    render: (r: any) => h(NTag, { type: r.side === 'buy' ? 'success' : 'error', size: 'small' }, { default: () => r.side })
  },
  // Only the `updated_at` column has `defaultSortOrder: 'descend'`
  // — naive-ui's initial sort on mount. NOTE: do NOT also set
  // `sortOrder: 'descend'` here. `sortOrder` is the CONTROLLED value
  // and naive-ui calls `@update:sorter` when the user clicks a header;
  // without an `@update:sorter` handler, clicks appear to do nothing
  // (the chevron is visible but the click is silently ignored).
  // `defaultSortOrder` is the UNCONTROLLED default — naive-ui manages
  // the state internally and clicks re-sort without any handler.
  { title: headerWithTerm('qty', 'Qty'), key: 'qty', sorter: 'default' },
  { title: headerWithTerm('filled_qty', 'Filled'), key: 'filled_qty', sorter: 'default' },
  { title: headerWithTerm('filled_avg_price', 'Avg Price'), key: 'filled_avg_price', sorter: 'default', render: (r: any) => fmtMoney(r.filled_avg_price) },
  { title: headerWithTerm('type', 'Type'), key: 'type', sorter: 'default' },
  {
    title: headerWithTerm('status', 'Status'),
    key: 'status',
    sorter: 'default',
    render: (r: any) => h(NTag, { type: statusType(r.status), size: 'small' }, { default: () => r.status })
  },
  { title: headerWithTerm('submitted_at', 'Submitted'), key: 'submitted_at', sorter: 'default' },
  { title: headerWithTerm('filled_at', 'Filled At'), key: 'filled_at', sorter: 'default' },
  { title: headerWithTerm('created_at', 'Created'), key: 'created_at', width: 130, sorter: 'default', render: (r: any) => fmtTimestamp(r.created_at) },
  { title: headerWithTerm('updated_at', 'Updated'), key: 'updated_at', width: 130, sorter: 'default', defaultSortOrder: 'descend', render: (r: any) => fmtTimestamp(r.updated_at) },
  { title: headerWithTerm('client_order_id', 'Client Order ID'), key: 'client_order_id', sorter: 'default' },
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

// Filter inputs (client-side state; pushed to the API on Refresh
// or implicitly on page change).
const statusFilter = ref<string | null>(null)
const symbolFilter = ref<string>('')

async function refresh() {
  await store.fetchPage({
    page: 1,                                  // always reset to first page on filter change
    status: statusFilter.value ?? undefined,
    symbol: symbolFilter.value.trim() || undefined
  })
}

async function onPageChange(payload: { page: number; per_page: number }) {
  await store.fetchPage({
    page: payload.page,
    perPage: payload.per_page,
    status: statusFilter.value ?? undefined,
    symbol: symbolFilter.value.trim() || undefined
  })
}

onMounted(refresh)
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">
        Yield-paca /
        <Term k="symbol" label="Orders" />
      </h1>
      <n-button @click="refresh" :loading="store.loading" size="small">Refresh</n-button>
    </div>

    <n-card style="margin-bottom: 16px;">
      <n-space>
        <n-input v-model:value="symbolFilter" placeholder="Filter by symbol…" clearable style="width: 200px;" @keyup.enter="refresh" />
        <n-select v-model:value="statusFilter" :options="[
          { label: 'new', value: 'new' },
          { label: 'filled', value: 'filled' },
          { label: 'partial', value: 'partial' },
          { label: 'cancelled', value: 'cancelled' },
          { label: 'expired', value: 'expired' }
        ]" placeholder="Filter by status…" clearable style="width: 200px;" @update:value="refresh" />
      </n-space>
    </n-card>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-card>
      <n-data-table
        :columns="columns"
        :data="store.items"
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
