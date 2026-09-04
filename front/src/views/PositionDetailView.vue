<script setup lang="ts">
import { onMounted, watch } from 'vue'
import { usePositionsStore } from '../stores/positions'

const props = defineProps<{ id: string }>()
const store = usePositionsStore()

const fmtMoney = (n: number | null | undefined) =>
  n == null ? '—' : n.toLocaleString('en-US', { style: 'currency', currency: 'USD' })
const fmtPct = (n: number | null | undefined) =>
  n == null ? '—' : `${(n * 100).toFixed(2)}%`

async function refresh() {
  await store.fetchOne(Number(props.id))
}

onMounted(refresh)
watch(() => props.id, refresh)
</script>

<template>
  <div>
    <h1 class="page-title">Yield-paca / Position #{{ props.id }}</h1>

    <n-alert v-if="store.error" type="error" :title="store.error" closable style="margin-bottom: 16px;" />

    <n-card v-if="store.detail?.position" title="Details" style="margin-bottom: 16px;">
      <n-descriptions :column="3" bordered>
        <n-descriptions-item label="Symbol">{{ store.detail.position.symbol }}</n-descriptions-item>
        <n-descriptions-item label="Qty">{{ store.detail.position.qty }}</n-descriptions-item>
        <n-descriptions-item label="Avg Entry">{{ fmtMoney(store.detail.position.avg_entry_price) }}</n-descriptions-item>
        <n-descriptions-item label="Market Value">{{ fmtMoney(store.detail.position.market_value) }}</n-descriptions-item>
        <n-descriptions-item label="Unrealized P&L">{{ fmtMoney(store.detail.position.unrealized_pl) }}</n-descriptions-item>
        <n-descriptions-item label="P&L %">{{ fmtPct(store.detail.position.unrealized_pl_pct) }}</n-descriptions-item>
        <n-descriptions-item label="Δ Delta">{{ store.detail.position.delta?.toFixed(2) ?? '—' }}</n-descriptions-item>
        <n-descriptions-item label="Γ Gamma">{{ store.detail.position.gamma?.toFixed(2) ?? '—' }}</n-descriptions-item>
        <n-descriptions-item label="Θ Theta">{{ store.detail.position.theta?.toFixed(2) ?? '—' }}</n-descriptions-item>
        <n-descriptions-item label="ν Vega">{{ store.detail.position.vega?.toFixed(2) ?? '—' }}</n-descriptions-item>
        <n-descriptions-item label="Snapshot At">{{ store.detail.position.snapshot_at }}</n-descriptions-item>
        <n-descriptions-item label="Closed At">{{ store.detail.position.closed_at ?? '— (open)' }}</n-descriptions-item>
      </n-descriptions>
    </n-card>

    <n-card title="Reviews" v-if="store.detail">
      <n-data-table
        :columns="[
          { title: 'Recommendation', key: 'recommendation' },
          { title: 'Thesis Still Valid', key: 'thesis_still_valid', render: (r: any) => r.thesis_still_valid == null ? '—' : (r.thesis_still_valid ? 'Yes' : 'No') },
          { title: 'Rationale', key: 'rationale' },
          { title: 'Created At', key: 'created_at' },
        ]"
        :data="store.detail.reviews"
        :bordered="false"
        :single-line="false"
        size="small"
      />
    </n-card>
  </div>
</template>
