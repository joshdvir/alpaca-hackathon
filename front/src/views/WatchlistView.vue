<script setup lang="ts">
import { h, onMounted, ref } from 'vue'
import { NTag, NTabPane, NTabs } from 'naive-ui'
import { useWatchlistStore } from '../stores/watchlist'
import Term from '../components/Term.vue'
import Pagination from '../components/Pagination.vue'

const store = useWatchlistStore()

const headerWithTerm = (key: string, fallback: string) =>
  () => h(Term, { k: key, label: fallback })

const columns = [
  { title: headerWithTerm('symbol', 'Ticker'), key: 'ticker' },
  { title: headerWithTerm('cycle_minutes', 'Cycle (min)'), key: 'cycle_minutes' },
  { title: headerWithTerm('source', 'Source'), key: 'source' },
  { title: headerWithTerm('tags', 'Tags'), key: 'tags', render: (r: any) => h(NTag, { type: 'info', size: 'small' }, { default: () => (r.tags || []).join(', ') || '—' }) },
  { title: headerWithTerm('effective_from', 'Effective From'), key: 'effective_from' },
  { title: headerWithTerm('last_cycle_started_at', 'Last Cycle'), key: 'last_cycle_started_at' },
]

const recColumns = [
  { title: headerWithTerm('symbol', 'Ticker'), key: 'ticker' },
  { title: headerWithTerm('effective_from', 'Recommended On'), key: 'recommended_on' },
  { title: headerWithTerm('source_filter', 'Filter'), key: 'source_filter' },
  { title: headerWithTerm('confidence', 'Confidence'), key: 'confidence', render: (r: any) => `${r.confidence}%` },
  { title: headerWithTerm('rationale', 'Rationale'), key: 'rationale' },
]

async function refreshAll() {
  await Promise.all([store.fetchEntries(), store.fetchRecommendations()])
}

async function onEntriesPageChange(p: { page: number; per_page: number }) {
  await store.fetchEntries({ page: p.page, perPage: p.per_page })
}

async function onRecsPageChange(p: { page: number; per_page: number }) {
  await store.fetchRecommendations({ page: p.page, perPage: p.per_page })
}

onMounted(refreshAll)
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / Watchlist</h1>
      <n-button @click="refreshAll" :loading="store.loading" size="small">Refresh</n-button>
    </div>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-tabs default-value="active" type="line">
      <n-tab-pane name="active" tab="Active">
        <n-card>
          <n-data-table
            :columns="columns"
            :data="store.entries"
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
            @change="onEntriesPageChange"
          />
        </n-card>
      </n-tab-pane>
      <n-tab-pane name="recommendations" tab="Recent Recommendations">
        <n-card>
          <n-data-table
            :columns="recColumns"
            :data="store.recommendations"
            :bordered="false"
            :single-line="false"
            size="small"
          />
          <Pagination
            :state="{
              page: store.recPage,
              per_page: store.recPerPage,
              total: store.recTotal,
              total_pages: store.recTotalPages
            }"
            :loading="store.loading"
            @change="onRecsPageChange"
          />
        </n-card>
      </n-tab-pane>
    </n-tabs>
  </div>
</template>
