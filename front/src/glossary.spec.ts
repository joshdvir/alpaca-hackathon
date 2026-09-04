// Glossary unit tests — pure TS, no Vue. The glossary is the
// foundation every Term component renders from, so we want strong
// coverage: every key the views reference must exist, every entry must
// have a non-empty label + definition, the lookup fallback must work,
// and the ALL_KEYS export must match the object.

import { describe, it, expect } from 'vitest'
import { GLOSSARY, ALL_KEYS, lookup } from './glossary'

describe('glossary', () => {
  it('ALL_KEYS matches the keys in GLOSSARY', () => {
    expect(new Set(ALL_KEYS)).toEqual(new Set(Object.keys(GLOSSARY)))
  })

  it('every entry has a non-empty label, definition, and matching key', () => {
    for (const key of ALL_KEYS) {
      const entry = GLOSSARY[key]
      expect(entry.key, `entry ${key} should echo its key`).toBe(key)
      expect(entry.label.length, `entry ${key} has empty label`).toBeGreaterThan(0)
      expect(entry.definition.length, `entry ${key} has empty definition`).toBeGreaterThan(20)
    }
  })

  it('definitions are plain prose (no Mustache placeholders or literal escapes)', () => {
    for (const key of ALL_KEYS) {
      const def = GLOSSARY[key].definition
      // Only catch unprocessed Mustache-style placeholders ({{var}} or
      // {{{var}}}). Curly braces in normal prose (e.g. "format like
      // {Strategy: vertical}") are fine.
      expect(def, `entry ${key} has an unprocessed {{mustache}} placeholder`).not.toMatch(/\{\{[a-z_]+\}\}/)
      // No JSON-style escapes leaking through
      expect(def, `entry ${key} contains literal \\n`).not.toContain('\\n')
    }
  })

  it('most entries have a label distinct from their key', () => {
    // Labels should be humanized prose, not raw snake_case. The
    // trading-side keywords (buy_to_open, etc.) are an exception —
    // those tokens are the API value AND the user-facing label,
    // because they map 1:1 with the broker's position_intent enum
    // and changing the visible string would hide the relationship.
    const allowedSnakeLabels = new Set(['buy_to_open', 'buy_to_close', 'sell_to_open', 'sell_to_close'])
    for (const key of ALL_KEYS) {
      if (allowedSnakeLabels.has(key)) continue
      const label = GLOSSARY[key].label
      expect(label, `entry ${key} label is identical to its snake_case key`).not.toBe(key)
    }
  })

  it('no duplicate keys (sanity — the object would silently merge them)', () => {
    // Object literal can't have true duplicate keys, but we can detect
    // collisions between entries whose `key` field disagrees with
    // the object key they live under.
    for (const objKey of Object.keys(GLOSSARY)) {
      expect(GLOSSARY[objKey].key).toBe(objKey)
    }
  })
})

describe('lookup', () => {
  it('returns the entry for a known key', () => {
    const entry = lookup('equity')
    expect(entry.key).toBe('equity')
    expect(entry.label).toBe('Equity')
    expect(entry.definition).toMatch(/account value/i)
  })

  it('returns a fallback for an unknown key (does not throw)', () => {
    const entry = lookup('not_a_real_term')
    expect(entry.key).toBe('not_a_real_term')
    expect(entry.label.length).toBeGreaterThan(0)
    expect(entry.definition.length).toBeGreaterThan(0)
    // The fallback should mention the glossary file so the missing
    // entry is easy to find and add.
    expect(entry.definition).toMatch(/glossary/i)
  })

  it('fallback humanizes snake_case keys', () => {
    const entry = lookup('weird_test_key')
    expect(entry.label).toBe('weird test key')
  })

  it('every key the views reference resolves to a real entry (not a fallback)', () => {
    // Whitelist of every glossary key referenced by the views we wired
    // up. If a view is updated to use a new key, add it here so the
    // test fails until the glossary catches up. This is the
    // single source of truth for "is the UI fully annotated".
    const keysUsedInViews = [
      // OrdersView
      'symbol', 'side', 'qty', 'filled_qty', 'filled_avg_price', 'type',
      'status', 'submitted_at', 'filled_at', 'client_order_id',
      'created_at', 'updated_at',
      'buy_to_open', 'buy_to_close', 'sell_to_open', 'sell_to_close',
      // PositionsView
      'avg_entry_price', 'market_value', 'unrealized_pl', 'unrealized_pl_pct',
      'unrealized_plpc', 'delta', 'theta', 'vega', 'plan',
      'created_at', 'updated_at', 'snapshot_at',
      // DashboardView
      'equity', 'cash', 'buying_power', 'options_buying_power', 'today_pl', 'watchlist',
      // WatchlistView
      'cycle_minutes', 'source', 'source_filter', 'confidence', 'rationale',
      'effective_from', 'tags', 'last_cycle_started_at',
      // AgentRunsView
      'agent_name', 'run_kind', 'model_used', 'duration_ms',
      'input_tokens', 'output_tokens', 'temporal_workflow_id',
      'error_message', 'strategy',
      // Strategies
      'vertical', 'straddle', 'strangle', 'calendar', 'iron_condor',
      'long_call', 'hold',
      // System concepts (used in tooltips / inline help)
      'circuit_breaker', 'rate_limit', 'iv', 'iv_rank', 'rsi',
      'alpaca_order_id', 'limit',
      // Dashboard / AccountPanel
      'account_panel', 'market_clock', 'open_positions', 'open_orders',
      'pending_sync', 'account_status', 'trading_blocked',
      'options_approved_level', 'multiplier', 'today_pl',
    ]
    for (const key of keysUsedInViews) {
      const entry = GLOSSARY[key]
      expect(entry, `glossary missing key ${key} referenced by a view`).toBeDefined()
      // And the definition shouldn't be the fallback
      expect(entry.definition, `glossary key ${key} is a fallback`).not.toMatch(/Add one in src\/glossary\.ts/)
    }
  })
})
