<script setup lang="ts">
import { computed, onMounted, onUnmounted, h } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useSystemStore } from './stores/system'
import { liveUpdates } from './api/liveUpdates'

const router = useRouter()
const route = useRoute()
const systemStore = useSystemStore()

const currentRoute = computed(() => route.path)

const menuOptions = [
  { label: 'Dashboard', key: '/' },
  { label: 'Positions', key: '/positions' },
  { label: 'Orders', key: '/orders' },
  { label: 'Watchlist', key: '/watchlist' },
  { label: 'Research', key: '/research' },
  { label: 'Agent Runs', key: '/agents' },
  { label: 'Backtests', key: '/backtests' },
  { label: 'System', key: '/system' },
  { label: 'Config', key: '/config' },
]

function onMenuSelect(key: string) {
  router.push(key)
}

onMounted(() => {
  // Open the ActionCable WebSocket once. Every store can subscribe to
  // the streams it cares about; the server fans out lifecycle events
  // (created/updated/destroyed) for every model that includes the
  // LiveUpdates concern. This replaces the previous 5–30s polling.
  liveUpdates.start()
  // Still do an initial REST fetch for the first paint; subsequent
  // updates come over the WebSocket.
  systemStore.fetchHealth()
})

onUnmounted(() => {
  liveUpdates.stop()
})
</script>

<template>
  <n-config-provider>
    <n-message-provider>
      <n-notification-provider>
        <n-dialog-provider>
          <n-layout style="height: 100vh">
            <n-layout-header bordered style="padding: 16px 24px; display: flex; align-items: center; justify-content: space-between;">
              <div style="font-size: 18px; font-weight: 600;">Yield-paca</div>
              <div>
                <n-tag
                  v-if="systemStore.health"
                  :type="systemStore.health.status === 'ok' ? 'success' : 'warning'"
                  size="small"
                  round
                >
                  {{ systemStore.health.status }}
                </n-tag>
                <n-tag v-else size="small" round>connecting…</n-tag>
              </div>
            </n-layout-header>

            <n-layout has-sider style="height: calc(100vh - 60px)">
              <n-layout-sider bordered :width="220" show-trigger>
                <n-menu
                  :value="currentRoute"
                  :options="menuOptions"
                  @update:value="onMenuSelect"
                />
              </n-layout-sider>

              <n-layout-content
                content-style="padding: 24px; background: #f5f7fa;"
                :native-scrollbar="false"
              >
                <router-view />
              </n-layout-content>
            </n-layout>
          </n-layout>
        </n-dialog-provider>
      </n-notification-provider>
    </n-message-provider>
  </n-config-provider>
</template>
