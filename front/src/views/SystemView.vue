<script setup lang="ts">
import { computed, h, onMounted, ref } from 'vue'
import { NTag, NSelect } from 'naive-ui'
import { useSystemStore } from '../stores/system'

const store = useSystemStore()
const window = ref<'1h' | '24h' | '7d'>('1h')

const windowOptions = [
  { label: '1 hour', value: '1h' },
  { label: '24 hours', value: '24h' },
  { label: '7 days', value: '7d' },
]

async function refresh() {
  await Promise.all([store.fetchHealth(), store.fetchRateLimits(window.value)])
}

onMounted(refresh)

const rateLimitSources = computed(() => {
  if (!store.rateLimits) return []
  return Object.entries(store.rateLimits.by_source).map(([source, statuses]) => ({
    source,
    success: statuses.success ?? 0,
    error: statuses.error ?? 0,
    rate_limited: statuses.rate_limited ?? 0,
    circuit_open: statuses.circuit_open ?? 0,
    avg_latency_ms: store.rateLimits?.avg_latency_ms_by_source[source] ?? null,
    circuit_state: store.rateLimits?.circuit_breakers[source]?.state ?? 'unknown',
  }))
})

const rateLimitColumns = [
  { title: 'Source', key: 'source' },
  { title: 'Success', key: 'success' },
  { title: 'Errors', key: 'error' },
  { title: 'Rate Limited', key: 'rate_limited' },
  { title: 'Circuit Open', key: 'circuit_open' },
  { title: 'Avg Latency (ms)', key: 'avg_latency_ms', render: (r: any) => r.avg_latency_ms?.toFixed(0) ?? '—' },
  {
    title: 'Circuit',
    key: 'circuit_state',
    render: (r: any) =>
      h(
        NTag,
        { type: r.circuit_state === 'closed' ? 'success' : 'warning', size: 'small' },
        { default: () => r.circuit_state }
      ),
  },
]
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Yield-paca / System</h1>
      <n-button @click="refresh" :loading="store.loading" size="small">Refresh</n-button>
    </div>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-card title="Health" style="margin-bottom: 16px;">
      <n-descriptions v-if="store.health" :column="3" bordered>
        <n-descriptions-item label="Status">
          <n-tag :type="store.health.status === 'ok' ? 'success' : 'warning'" round>
            {{ store.health.status }}
          </n-tag>
        </n-descriptions-item>
        <n-descriptions-item label="DB">
          <n-tag :type="store.health.db ? 'success' : 'error'" round>
            {{ store.health.db ? 'connected' : 'down' }}
          </n-tag>
        </n-descriptions-item>
        <n-descriptions-item label="Temporal">
          <n-tag :type="store.health.temporal ? 'success' : 'error'" round>
            {{ store.health.temporal ? 'connected' : 'down' }}
          </n-tag>
        </n-descriptions-item>
        <n-descriptions-item label="Open Positions">{{ store.health.open_positions_count }}</n-descriptions-item>
        <n-descriptions-item label="Active Watchlist">{{ store.health.active_watchlist_count }}</n-descriptions-item>
        <n-descriptions-item label="Kill Switch">
          <n-tag :type="store.health.kill_switch ? 'error' : 'success'" round>
            {{ store.health.kill_switch ? 'ON' : 'off' }}
          </n-tag>
        </n-descriptions-item>
        <n-descriptions-item label="Last Agent Run">{{ store.health.last_agent_name ?? '—' }}</n-descriptions-item>
        <n-descriptions-item label="Last Run At">{{ store.health.last_agent_run_at ?? '—' }}</n-descriptions-item>
        <n-descriptions-item label="Server Time">{{ store.health.server_time }}</n-descriptions-item>
      </n-descriptions>
    </n-card>

    <n-card title="Rate Limits">
      <template #header-extra>
        <n-select
          v-model:value="window"
          :options="windowOptions"
          size="small"
          style="width: 140px;"
          @update:value="refresh"
        />
      </template>
      <n-data-table
        :columns="rateLimitColumns"
        :data="rateLimitSources"
        :bordered="false"
        :single-line="false"
        size="small"
      />
    </n-card>
  </div>
</template>
