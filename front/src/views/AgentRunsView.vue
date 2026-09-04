<script setup lang="ts">
import { computed, h, onMounted, ref } from 'vue'
import { NTag, NInput, NSelect } from 'naive-ui'
import { useAgentRunsStore } from '../stores/agentRuns'
import Term from '../components/Term.vue'
import Pagination from '../components/Pagination.vue'

const store = useAgentRunsStore()

const agentFilter = ref<string | null>(null)
const kindFilter = ref<string | null>(null)
const statusFilter = ref<string | null>(null)
const tickerFilter = ref<string | null>(null)

const agentOptions = computed(() => {
  const names = store.distinct?.agent_names ?? []
  return names.map((n) => ({ label: n, value: n }))
})
const kindOptions = computed(() => {
  const kinds = store.distinct?.run_kinds ?? []
  return kinds.map((k) => ({ label: k, value: k }))
})
const statusOptions = computed(() => {
  const statuses = store.distinct?.statuses ?? []
  return statuses.map((s) => ({ label: s, value: s }))
})

const statusType = (s: string) =>
  s === 'success' ? 'success' : s === 'error' ? 'error' : 'warning'

const headerWithTerm = (key: string, fallback: string) =>
  () => h(Term, { k: key, label: fallback })

const columns = [
  { title: headerWithTerm('agent_name', 'Agent'), key: 'agent_name' },
  { title: headerWithTerm('run_kind', 'Kind'), key: 'run_kind' },
  { title: headerWithTerm('symbol', 'Ticker'), key: 'ticker' },
  {
    title: headerWithTerm('status', 'Status'),
    key: 'status',
    render: (r: any) => h(NTag, { type: statusType(r.status), size: 'small' }, { default: () => r.status }),
  },
  { title: headerWithTerm('model_used', 'Model'), key: 'model_used' },
  {
    title: () => h('span', null, [h(Term, { k: 'input_tokens', label: 'Input' }), ' + ', h(Term, { k: 'output_tokens', label: 'Output' })]),
    key: 'tokens',
    render: (r: any) => (r.input_tokens ?? 0) + (r.output_tokens ?? 0)
  },
  { title: headerWithTerm('duration_ms', 'Duration (ms)'), key: 'duration_ms' },
  { title: headerWithTerm('temporal_workflow_id', 'Workflow ID'), key: 'temporal_workflow_id' },
  { title: 'Created', key: 'created_at' },
  { title: headerWithTerm('rationale', 'Rationale'), key: 'rationale', ellipsis: { tooltip: true } },
]

function commonOpts() {
  return {
    agent: agentFilter.value ?? undefined,
    run_kind: kindFilter.value ?? undefined,
    status: statusFilter.value ?? undefined,
    ticker: tickerFilter.value ?? undefined
  } as const
}

async function refresh() {
  await store.fetchPage({ page: 1, ...commonOpts() })
}

async function onPageChange(p: { page: number; per_page: number }) {
  await store.fetchPage({ page: p.page, perPage: p.per_page, ...commonOpts() })
}

onMounted(async () => {
  await store.fetchDistinct()
  await refresh()
})
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / Agent Runs</h1>
      <n-button @click="refresh" :loading="store.loading" size="small">Refresh</n-button>
    </div>

    <n-card style="margin-bottom: 16px;">
      <n-space>
        <n-select
          v-model:value="agentFilter"
          :options="agentOptions"
          placeholder="Filter by agent…"
          clearable
          style="width: 240px;"
          @update:value="refresh"
        />
        <n-select
          v-model:value="kindFilter"
          :options="kindOptions"
          placeholder="Filter by kind…"
          clearable
          style="width: 160px;"
          @update:value="refresh"
        />
        <n-select
          v-model:value="statusFilter"
          :options="statusOptions"
          placeholder="Filter by status…"
          clearable
          style="width: 160px;"
          @update:value="refresh"
        />
        <n-input
          v-model:value="tickerFilter"
          placeholder="Filter by ticker…"
          style="width: 180px;"
          @keyup.enter="refresh"
        />
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
