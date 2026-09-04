<script setup lang="ts">
import { h, computed, onMounted, onUnmounted } from 'vue'
import { useAccountStore } from '../stores/account'
import Term from './Term.vue'

const account = useAccountStore()

const fmtMoney = (n: number | null | undefined) =>
  n == null ? '—' : n.toLocaleString('en-US', { style: 'currency', currency: 'USD' })
const fmtPct = (n: number | null | undefined) =>
  n == null ? '—' : `${(n * 100).toFixed(2)}%`
const fmtSignedMoney = (n: number | null | undefined) => {
  if (n == null) return '—'
  const sign = n >= 0 ? '+' : '−'
  return `${sign}${Math.abs(n).toLocaleString('en-US', { style: 'currency', currency: 'USD' })}`
}
const fmtDate = (s: string | null | undefined) => {
  if (!s) return '—'
  const d = new Date(s)
  return d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}
const fmtTimeUntil = (seconds: number | null | undefined) => {
  if (seconds == null) return '—'
  if (seconds <= 0) return 'now'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

const plColor = computed(() => {
  const v = account.snapshot?.daily_pl ?? 0
  if (v > 0) return 'var(--success-color, #16a34a)'
  if (v < 0) return 'var(--error-color, #dc2626)'
  return 'var(--text-secondary, #6b7280)'
})

const statusColor = computed(() => {
  if (!account.snapshot) return 'var(--text-secondary, #6b7280)'
  if (account.snapshot.trading_blocked) return 'var(--error-color, #dc2626)'
  switch (account.snapshot.status) {
    case 'ACTIVE': return 'var(--success-color, #16a34a)'
    case 'INACTIVE': return 'var(--text-secondary, #6b7280)'
    default: return 'var(--text-secondary, #6b7280)'
  }
})

async function refresh() {
  await account.fetch()
}
async function refreshNow() {
  await account.refreshNow()
}

let pollHandle: number | undefined
onMounted(async () => {
  await refresh()
  // Account data refreshes every 30s on the server; poll our
  // local cache to keep the UI live. The actual broker call only
  // happens server-side.
  pollHandle = window.setInterval(refresh, 15_000)
})
onUnmounted(() => {
  if (pollHandle !== undefined) clearInterval(pollHandle)
})
</script>

<template>
  <div class="account-panel">
    <div class="account-panel__header">
      <h2>Alpaca Account
        <Term k="account_panel" />
      </h2>
      <div class="account-panel__actions">
        <span class="account-panel__as-of" v-if="account.lastFetchedAt">
          Updated {{ account.lastFetchedAt.toLocaleTimeString() }}
        </span>
        <button class="account-panel__refresh" @click="refreshNow" :disabled="account.refreshing">
          {{ account.refreshing ? 'Syncing…' : 'Sync now' }}
        </button>
      </div>
    </div>

    <div v-if="account.error" class="account-panel__error">{{ account.error }}</div>

    <div v-if="!account.snapshot" class="account-panel__empty">
      <p>No Alpaca snapshot yet. The mirror job will populate this within 30s of the worker starting.</p>
    </div>

    <div v-else class="account-panel__grid">
      <!-- LEFT: account + market -->
      <div class="account-panel__column">
        <div class="account-panel__metric">
          <div class="label">Account status</div>
          <div class="value" :style="{ color: statusColor }">
            <span class="dot" :style="{ background: statusColor }"></span>
            {{ account.snapshot.status || 'UNKNOWN' }}
            <span v-if="account.snapshot.trading_blocked" class="blocked">⚠ trading blocked</span>
          </div>
          <div class="sublabel">acct #{{ account.snapshot.account_number || '—' }}</div>
        </div>

        <div class="account-panel__metric">
          <div class="label">Equity</div>
          <div class="value value--big">{{ fmtMoney(account.snapshot.equity) }}</div>
          <div class="sublabel" :style="{ color: plColor }">
            Day P&amp;L {{ fmtSignedMoney(account.snapshot.daily_pl) }}
            <span v-if="account.snapshot.last_equity != null">
              ({{ fmtPct(account.snapshot.daily_pl / account.snapshot.last_equity) }})
            </span>
          </div>
        </div>

        <div class="account-panel__row">
          <div class="account-panel__metric account-panel__metric--half">
            <div class="label">Cash</div>
            <div class="value">{{ fmtMoney(account.snapshot.cash) }}</div>
          </div>
          <div class="account-panel__metric account-panel__metric--half">
            <div class="label">Buying power</div>
            <div class="value">{{ fmtMoney(account.snapshot.buying_power) }}</div>
            <div class="sublabel">{{ account.snapshot.multiplier || '1' }}× margin</div>
          </div>
        </div>

        <div class="account-panel__row">
          <div class="account-panel__metric account-panel__metric--half">
            <div class="label">Options BP</div>
            <div class="value">{{ fmtMoney(account.snapshot.options_buying_power) }}</div>
          </div>
          <div class="account-panel__metric account-panel__metric--half">
            <div class="label">Options level</div>
            <div class="value">L{{ account.snapshot.options_approved_level ?? '—' }}</div>
            <div class="sublabel">0=off, 1=CC, 2=long, 3=spreads</div>
          </div>
        </div>
      </div>

      <!-- RIGHT: positions + orders + market clock -->
      <div class="account-panel__column">
        <div class="account-panel__metric">
          <div class="label">Market
            <Term k="market_clock" />
          </div>
          <div class="value" :style="{ color: account.market?.is_open ? 'var(--success-color, #16a34a)' : 'var(--text-secondary, #6b7280)' }">
            {{ account.market?.is_open ? 'OPEN' : 'CLOSED' }}
          </div>
          <div class="sublabel" v-if="account.market">
            <template v-if="account.market.is_open">
              closes {{ fmtDate(account.market.next_close) }}
            </template>
            <template v-else>
              opens {{ fmtDate(account.market.next_open) }}
              ({{ fmtTimeUntil(account.market.seconds_until_next_open) }})
            </template>
          </div>
        </div>

        <div class="account-panel__metric">
          <div class="label">Open positions
            <Term k="open_positions" />
          </div>
          <div class="value">{{ account.overview?.open_position_count ?? 0 }}</div>
          <div v-if="account.positions.length > 0" class="positions-list">
            <div v-for="p in account.positions.slice(0, 5)" :key="p.symbol" class="positions-list__row">
              <span class="symbol">{{ p.symbol }}</span>
              <span class="qty">×{{ p.qty }}</span>
              <span class="pl" :style="{ color: p.unrealized_pl >= 0 ? 'var(--success-color, #16a34a)' : 'var(--error-color, #dc2626)' }">
                {{ fmtSignedMoney(p.unrealized_pl) }}
              </span>
            </div>
            <div v-if="account.positions.length > 5" class="positions-list__more">
              +{{ account.positions.length - 5 }} more
            </div>
          </div>
        </div>

        <div class="account-panel__row">
          <div class="account-panel__metric account-panel__metric--half">
            <div class="label">Open orders
              <Term k="open_orders" />
            </div>
            <div class="value">{{ account.openOrders.length }}</div>
          </div>
          <div class="account-panel__metric account-panel__metric--half">
            <div class="label">Pending sync
              <Term k="pending_sync" />
            </div>
            <div class="value" :style="{ color: (account.overview?.pending_sync_order_count ?? 0) > 0 ? 'var(--warning-color, #d97706)' : 'var(--text-secondary, #6b7280)' }">
              {{ account.overview?.pending_sync_order_count ?? 0 }}
            </div>
          </div>
        </div>

        <div v-if="(account.overview?.rejected_last_24h ?? 0) > 0" class="account-panel__warning">
          ⚠ {{ account.overview?.rejected_last_24h }} order(s) rejected by broker in the last 24h. Check Orders view.
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.account-panel {
  background: var(--surface-color, #ffffff);
  border: 1px solid var(--border-color, #e5e7eb);
  border-radius: 8px;
  padding: 20px;
  margin-bottom: 24px;
}
.account-panel__header {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 16px;
}
.account-panel__header h2 {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 8px;
}
.account-panel__actions {
  display: flex;
  gap: 12px;
  align-items: center;
  font-size: 12px;
  color: var(--text-secondary, #6b7280);
}
.account-panel__refresh {
  background: var(--primary-color, #2563eb);
  color: white;
  border: none;
  border-radius: 4px;
  padding: 6px 12px;
  font-size: 12px;
  cursor: pointer;
}
.account-panel__refresh:disabled {
  background: var(--text-secondary, #9ca3af);
  cursor: not-allowed;
}
.account-panel__error {
  background: var(--error-bg, #fef2f2);
  color: var(--error-color, #dc2626);
  padding: 8px 12px;
  border-radius: 4px;
  font-size: 13px;
  margin-bottom: 12px;
}
.account-panel__empty {
  text-align: center;
  color: var(--text-secondary, #6b7280);
  padding: 24px;
  font-size: 14px;
}
.account-panel__grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 24px;
}
.account-panel__column {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.account-panel__row {
  display: flex;
  gap: 16px;
}
.account-panel__metric {
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.account-panel__metric--half {
  flex: 1;
}
.account-panel__metric .label {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-secondary, #6b7280);
  font-weight: 500;
  display: flex;
  align-items: center;
  gap: 4px;
}
.account-panel__metric .value {
  font-size: 20px;
  font-weight: 600;
  color: var(--text-color, #1f2937);
}
.account-panel__metric .value--big {
  font-size: 26px;
}
.account-panel__metric .value .dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  margin-right: 4px;
}
.account-panel__metric .sublabel {
  font-size: 12px;
  color: var(--text-secondary, #6b7280);
}
.blocked {
  background: var(--error-bg, #fef2f2);
  color: var(--error-color, #dc2626);
  padding: 1px 6px;
  border-radius: 3px;
  font-size: 11px;
  font-weight: 500;
  margin-left: 4px;
}
.positions-list {
  margin-top: 8px;
  font-size: 13px;
}
.positions-list__row {
  display: grid;
  grid-template-columns: 1fr auto auto;
  gap: 8px;
  padding: 2px 0;
  align-items: baseline;
}
.positions-list__row .symbol {
  font-family: monospace;
}
.positions-list__row .qty {
  color: var(--text-secondary, #6b7280);
}
.positions-list__more {
  color: var(--text-secondary, #6b7280);
  font-style: italic;
  margin-top: 4px;
}
.account-panel__warning {
  background: var(--warning-bg, #fffbeb);
  color: var(--warning-color, #b45309);
  padding: 8px 12px;
  border-radius: 4px;
  font-size: 13px;
}
@media (max-width: 900px) {
  .account-panel__grid { grid-template-columns: 1fr; }
}
</style>
