<script setup lang="ts">
import { h, onMounted, ref, computed } from 'vue'
import { NTag, NInput, NTabs, NTabPane } from 'naive-ui'
import { useResearchStore } from '../stores/research'

const store = useResearchStore()
const tickerFilter = ref('')

async function refresh() {
  await store.fetch(tickerFilter.value || undefined)
}

async function applyFilter() {
  await refresh()
}

const recType = (r: string) =>
  r === 'bullish' ? 'success' : r === 'bearish' ? 'error' : 'default'

// Columns that hold long free-form text need `ellipsis: false` (so
// naiveUI doesn't truncate) + a className (so scoped CSS can apply
// `white-space: normal` + word-break) + an explicit `width` (so the
// table doesn't auto-shrink the other columns to 1 char wide when
// the wrap column is long). The other columns keep naiveUI's
// default single-line ellipsis.
const WRAP = { ellipsis: false as const, className: 'col-wrap-text' } as const

const planColumns = computed(() => [
  { title: 'Ticker', key: 'ticker', width: 80 },
  { title: 'Rec.', key: 'recommendation', width: 100, render: (r: any) => h(NTag, { type: recType(r.recommendation), size: 'small' }, { default: () => r.recommendation }) },
  { title: 'Conf.', key: 'confidence', width: 80, render: (r: any) => `${r.confidence}%` },
  { title: 'Valid Until', key: 'valid_until', width: 150 },
  { title: 'Catalysts', key: 'key_catalysts', ...WRAP, width: 260, render: (r: any) => (r.key_catalysts || []).join('; ') },
  { title: 'Invalidation', key: 'invalidation_conditions', ...WRAP, width: 240, render: (r: any) => (r.invalidation_conditions || []).join('; ') },
  { title: 'Synthesis', key: 'synthesis', ...WRAP, width: 360 },
])

const caseColumns = [
  { title: 'Ticker', key: 'ticker', width: 80 },
  { title: 'Conf.', key: 'confidence', width: 80, render: (r: any) => `${r.confidence}%` },
  { title: 'Narrative', key: 'narrative', ...WRAP, width: 600 },
  { title: 'Created At', key: 'created_at', width: 150 },
]

const reportColumns = [
  { title: 'Analyst', key: 'analyst_name', width: 130 },
  { title: 'Ticker', key: 'ticker', width: 80 },
  { title: 'Conf.', key: 'confidence', width: 80, render: (r: any) => `${r.confidence}%` },
  { title: 'Freshness', key: 'data_freshness', width: 110, render: (r: any) => h(NTag, { type: r.data_freshness === 'fresh' ? 'success' : 'warning', size: 'small' }, { default: () => r.data_freshness }) },
  { title: 'Summary', key: 'summary', ...WRAP, width: 400 },
  { title: 'Created At', key: 'created_at', width: 150 },
]

onMounted(refresh)
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / Research</h1>
      <div style="display: flex; gap: 8px;">
        <n-input v-model:value="tickerFilter" placeholder="Filter by ticker…" size="small" style="width: 200px;" @keyup.enter="applyFilter" />
        <n-button @click="applyFilter" :loading="store.loading" size="small">Apply</n-button>
      </div>
    </div>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-tabs default-value="plans" type="line">
      <n-tab-pane name="plans" :tab="`Research Plans (${store.summary?.research_plans?.items?.length ?? 0})`">
        <n-card>
          <n-data-table
            :columns="planColumns"
            :data="store.summary?.research_plans?.items ?? []"
            :bordered="false"
            :single-line="false"
            :scroll-x="1280"
            size="small"
          />
        </n-card>
      </n-tab-pane>
      <n-tab-pane name="bull" :tab="`Bull Cases (${store.summary?.bull_cases?.items?.length ?? 0})`">
        <n-card>
          <n-data-table
            :columns="caseColumns"
            :data="store.summary?.bull_cases?.items ?? []"
            :bordered="false"
            :single-line="false"
            :scroll-x="920"
            size="small"
          />
        </n-card>
      </n-tab-pane>
      <n-tab-pane name="bear" :tab="`Bear Cases (${store.summary?.bear_cases?.items?.length ?? 0})`">
        <n-card>
          <n-data-table
            :columns="caseColumns"
            :data="store.summary?.bear_cases?.items ?? []"
            :bordered="false"
            :single-line="false"
            :scroll-x="920"
            size="small"
          />
        </n-card>
      </n-tab-pane>
      <n-tab-pane name="analyst" :tab="`Analyst Reports (${store.summary?.analyst_reports?.items?.length ?? 0})`">
        <n-card>
          <n-data-table
            :columns="reportColumns"
            :data="store.summary?.analyst_reports?.items ?? []"
            :bordered="false"
            :single-line="false"
            :scroll-x="960"
            size="small"
          />
        </n-card>
      </n-tab-pane>
    </n-tabs>
  </div>
</template>

<style scoped>
/* Columns tagged with className="col-wrap-text" (the WRAP constant
   above) wrap long free-form text on word boundaries. The other
   columns keep naiveUI's default single-line ellipsis. The
   `min-width` is the actual floor: without it, naiveUI auto-shrinks
   the column to a single char wide when the content is long, which
   makes headers rotate vertically and content break one char per
   line. The per-column `width:` props above set the IDEAL width;
   this CSS sets the floor so a long string still has readable
   column space. */
.col-wrap-text {
  white-space: normal !important;
  word-break: break-word;
  min-width: 240px;
}
</style>
