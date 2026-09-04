// Type definitions matching the Rails API serializers.
// Keep these in sync with app/controllers/api/* in the api project.

export interface DashboardSummary {
  equity: number | null
  cash: number | null
  buying_power: number | null
  options_buying_power: number | null
  today_pl: number | null
  open_positions_count: number
  active_watchlist_count: number
  last_run_at: string | null
  last_run_agent: string | null
  server_time: string
}

export interface Position {
  id: number
  symbol: string
  qty: number | null
  avg_entry_price: number | null
  market_value: number | null
  unrealized_pl: number | null
  unrealized_plpc: number | null
  // Mid-Band Movers (and any future strategy-managed position) carries
  // these fields; default-strategy positions leave them null.
  origin: string | null
  strategy_bucket: string | null
  planned_sell_at: string | null
  delta: number | null
  gamma: number | null
  theta: number | null
  vega: number | null
  snapshot_at: string
  closed_at: string | null
}

export interface PositionDetail {
  position: Position
  reviews: PositionReview[]
}

export interface PositionReview {
  id: number
  recommendation: string
  rationale: string | null
  thesis_still_valid: boolean | null
  created_at: string
}

export interface Order {
  id: number
  client_order_id: string
  alpaca_order_id: string | null
  symbol: string
  side: string
  qty: number
  filled_qty: number
  filled_avg_price: number | null
  type: string
  status: string
  submitted_at: string | null
  filled_at: string | null
  created_at: string
}

export interface WatchlistEntry {
  ticker: string
  effective_from: string
  effective_until: string | null
  source: string
  cycle_minutes: number
  tags: string[] | null
  last_cycle_started_at: string | null
  last_temporal_run_id: string | null
}

export interface WatchlistRecommendation {
  ticker: string
  recommended_on: string
  source_filter: string
  confidence: number
  scores: Record<string, unknown> | null
  rationale: string | null
}

export interface ResearchPlan {
  id: number
  ticker: string
  recommendation: string
  confidence: number
  synthesis: string | null
  key_catalysts: string[] | null
  invalidation_conditions: string[] | null
  valid_until: string
  created_at: string
}

export interface BullCase {
  id: number
  kind: string
  ticker: string
  confidence: number
  narrative: string | null
  payload: Record<string, unknown> | null
  created_at: string
}

export interface AnalystReport {
  id: number
  analyst_name: string
  ticker: string
  data_freshness: string
  payload: Record<string, unknown> | null
  created_at: string
}

export interface ResearchSummary {
  // Each collection is a paginated response from the API; the view
  // reads .items to render the table and .items.length for the tab
  // badge. Keeping the full envelope (not just .items) leaves room
  // for adding a Pagination component later without changing the
  // type.
  research_plans: PaginatedResponse<ResearchPlan>
  bull_cases: PaginatedResponse<BullCase>
  bear_cases: PaginatedResponse<BearCase>
  analyst_reports: PaginatedResponse<AnalystReport>
}

export interface AgentRun {
  id: number
  agent_name: string
  run_kind: string
  ticker: string | null
  status: string
  rationale: string | null
  model_used: string | null
  input_tokens: number | null
  output_tokens: number | null
  duration_ms: number | null
  error_message: string | null
  temporal_workflow_id: string | null
  created_at: string
}

export interface ToolCall {
  id: number
  tool_name: string
  source: string
  status: string
  http_status: number | null
  duration_ms: number | null
  retry_count: number
  created_at: string
}

export interface AgentRunDetail {
  id: number
  agent_name: string
  run_kind: string
  ticker: string | null
  status: string
  rationale: string | null
  model_used: string | null
  input_tokens: number | null
  output_tokens: number | null
  duration_ms: number | null
  error_message: string | null
  temporal_workflow_id: string | null
  created_at: string
  tool_calls: ToolCall[]
}

export interface SystemHealth {
  status: 'ok' | 'degraded'
  server_time: string
  db: boolean
  temporal: boolean
  active_watchlist_count: number
  open_positions_count: number
  last_agent_run_at: string | null
  last_agent_name: string | null
  kill_switch: boolean
}

export interface RateLimitStats {
  window: string
  since: string
  by_source: Record<string, Record<string, number>>
  avg_latency_ms_by_source: Record<string, number | null>
  circuit_breakers: Record<string, { state: string }>
}

export interface TradingConfigView {
  config: Record<string, unknown>
  loaded_from: string
}

export interface BacktestRun {
  id: number
  name: string | null
  tickers: string[]
  period_days: number
  mode: 'full' | 'deterministic' | 'hybrid'
  status: 'pending' | 'running' | 'success' | 'error' | 'cancelled'
  start_of_day_equity: number | null
  final_equity: number | null
  total_pnl: number | null
  total_trades: number
  winning_trades: number
  win_rate: number
  max_drawdown: number | null
  sharpe: number | null
  started_at: string | null
  finished_at: string | null
  duration_seconds: number | null
  error_message: string | null
  temporal_workflow_id: string | null
  temporal_run_id: string | null
  trade_count?: number
  created_at: string
  updated_at: string
}

export interface BacktestRunStatus {
  id: number
  status: BacktestRun['status']
  total_trades: number
  total_pnl: number | null
  final_equity: number | null
  started_at: string | null
  finished_at: string | null
  error_message: string | null
}

export interface BacktestTrade {
  id: number
  ticker: string
  strategy_type: string | null
  legs: Array<{
    side?: string
    ratio_qty?: number
    option_symbol?: string
    limit_price?: number
  }> | null
  entry_price: number | null
  exit_price: number | null
  pnl: number | null
  winner: boolean
  holding_minutes: number | null
  opened_at: string | null
  closed_at: string | null
}

export interface CreateBacktestInput {
  tickers: string[]
  period_days: number
  mode?: 'full' | 'deterministic' | 'hybrid'
  start_of_day_equity?: number
  name?: string
}

// Paginated list response. Every list endpoint that supports
// `?page=N&per_page=M` returns this shape; the front-end Pagination
// component reads `state` from this and emits `change` events to
// the parent view which re-fetches with the new page.
export interface PaginatedResponse<T> {
  items: T[]
  total: number
  page: number
  per_page: number
  total_pages: number
}

// Account — live mirror of the Alpaca broker account, refreshed every
// 30s by the server. The dashboard "Account" panel renders from this.
export interface AccountSnapshot {
  id: number
  equity: number
  cash: number
  buying_power: number
  options_buying_power: number
  portfolio_value: number | null
  last_equity: number | null
  daily_pl: number
  status: string | null
  account_number: string | null
  options_approved_level: number | null
  trading_blocked: boolean
  multiplier: string | null
  as_of: string
}

export interface AccountPosition {
  symbol: string
  qty: number
  avg_entry_price: number
  market_value: number
  unrealized_pl: number
  unrealized_plpc: number
  snapshot_at: string
}

export interface AccountOpenOrder {
  id: number
  symbol: string
  side: string
  qty: number
  status: string
  limit_price: number | null
  created_at: string
}

export interface AccountMarket {
  is_open: boolean
  next_open: string | null
  next_close: string | null
  as_of: string
  source: string
  seconds_until_next_open: number | null
}

export interface AccountOverview {
  snapshot: AccountSnapshot | null
  positions: AccountPosition[]
  open_position_count: number
  open_orders: AccountOpenOrder[]
  pending_sync_order_count: number
  rejected_last_24h: number
  market: AccountMarket
  server_time: string
}
