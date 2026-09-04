<script setup lang="ts">
// Pagination — render a page indicator + prev/next buttons for a
// paginated list. The parent owns the actual data fetch (so the
// same component can be reused on every list view), this just
// emits 'change' events when the user clicks prev/next/page.
import { computed } from 'vue'
import { NButton, NSelect, NSpace } from 'naive-ui'

interface PageState {
  page: number
  per_page: number
  total: number
  total_pages: number
}

const props = withDefaults(
  defineProps<{
    /** Current page state from the paginated API response. */
    state: PageState
    /** Disabled state (e.g. while a refetch is in flight). */
    loading?: boolean
  }>(),
  { loading: false }
)

const emit = defineEmits<{
  (e: 'change', payload: { page: number; per_page: number }): void
}>()

const start = computed(() => {
  if (props.state.total === 0) return 0
  return (props.state.page - 1) * props.state.per_page + 1
})
const end = computed(() => {
  return Math.min(props.state.page * props.state.per_page, props.state.total)
})

const perPageOptions = [
  { label: '25 / page',  value: 25 },
  { label: '50 / page',  value: 50 },
  { label: '100 / page', value: 100 },
  { label: '200 / page', value: 200 }
]

function goToPage(p: number) {
  if (p < 1 || p > props.state.total_pages) return
  if (p === props.state.page) return
  emit('change', { page: p, per_page: props.state.per_page })
}

function changePerPage(p: number) {
  // Changing per_page usually means we want to see the first page at
  // the new density.
  emit('change', { page: 1, per_page: p })
}
</script>

<template>
  <div class="pagination" v-if="state.total > 0 || state.total_pages > 0">
    <n-space align="center" justify="space-between" :wrap="false">
      <span class="muted" style="font-size: 12px;">
        Showing
        <strong>{{ start }}–{{ end }}</strong>
        of
        <strong>{{ state.total.toLocaleString() }}</strong>
        items
      </span>

      <n-space :wrap="false" :size="4" align="center">
        <n-select
          :value="state.per_page"
          :options="perPageOptions"
          size="small"
          style="width: 110px;"
          :disabled="loading"
          @update:value="changePerPage"
        />

        <n-button
          size="small"
          :disabled="loading || state.page <= 1"
          @click="goToPage(state.page - 1)"
        >
          ← Prev
        </n-button>

        <span class="pagination__page">
          Page
          <strong>{{ state.page }}</strong>
          of
          <strong>{{ Math.max(state.total_pages, 1) }}</strong>
        </span>

        <n-button
          size="small"
          :disabled="loading || state.page >= state.total_pages"
          @click="goToPage(state.page + 1)"
        >
          Next →
        </n-button>
      </n-space>
    </n-space>
  </div>
</template>

<style scoped>
.pagination {
  margin-top: 12px;
  padding: 8px 12px;
  background: #fafafa;
  border-top: 1px solid #eee;
  border-radius: 0 0 4px 4px;
}
.pagination__page {
  font-size: 12px;
  color: #555;
  padding: 0 8px;
}
</style>
