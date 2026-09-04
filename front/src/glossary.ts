// Financial + system term definitions for the Yield-paca front-end.
//
// Every term the UI can show should be in this file. Components import
// `lookup(key)` to get the `{label, definition}` pair, and the <Term>
// wrapper renders the label with a hover popover showing the definition.
//
// Keys are short snake_case identifiers, not free text — the views
// reference keys explicitly, which means a glossary refactor is
// type-checked (TS will flag any view that uses an unknown key).
//
// Add new terms here as features grow. Keep the language plain-English
// and beginner-friendly; the user asked for explanations "wherever
// there is a financial word" so a non-trader reading the dashboard
// should be able to follow along.

export interface GlossaryEntry {
  /** Short identifier referenced by the views. */
  key: string
  /** The visible word/phrase (e.g. "Equity"). */
  label: string
  /** Plain-English explanation shown in the hover popover. */
  definition: string
}

export const GLOSSARY: Record<string, GlossaryEntry> = {
  // ---- Account / portfolio basics ----
  equity: {
    key: 'equity',
    label: 'Equity',
    definition:
      "Your total account value: cash plus the current market value of every open position. Goes up when your positions gain value or you realize profit, down when they lose value or you pay commissions/fees."
  },
  cash: {
    key: 'cash',
    label: 'Cash',
    definition:
      'The uninvested cash sitting in your brokerage account. Not earning interest, but available to deploy into new positions or to absorb margin requirements.'
  },
  buying_power: {
    key: 'buying_power',
    label: 'Buying Power',
    definition:
      'The total dollar amount you can immediately deploy into new trades. For a cash account this equals your cash. For a margin account it can be 2x or 4x your cash depending on the broker (regulatory margin).'
  },
  options_buying_power: {
    key: 'options_buying_power',
    label: 'Options BP',
    definition:
      'The portion of your buying power reserved for options trades. Options positions have their own margin requirements (defined risk vs undefined risk strategies).'
  },
  today_pl: {
    key: 'today_pl',
    label: "Today's P&L",
    definition:
      "Profit and Loss realized or marked-to-market since market open today. Green = up, red = down. Combines closed trades' realized P&L with open positions' intraday price moves."
  },

  // ---- Order fields ----
  symbol: {
    key: 'symbol',
    label: 'Symbol',
    definition:
      'The unique ticker that identifies the security. For options, it is the full OCC symbol like "AAPL250117C00150000" which encodes the underlying, expiration (YYYYMMDD), side (C=Call, P=Put), and strike (×1000).'
  },
  side: {
    key: 'side',
    label: 'Side',
    definition:
      'The direction of the trade. For stocks: "buy" or "sell". For options: "buy_to_open" (open a new long position), "buy_to_close" (close an existing short), "sell_to_open" (open a new short position by writing the contract), "sell_to_close" (close an existing long).'
  },
  qty: {
    key: 'qty',
    label: 'Qty',
    definition:
      'The order quantity. For stocks: number of shares. For options: number of contracts. Each option contract controls 100 shares of the underlying (a "single leg").'
  },
  filled_qty: {
    key: 'filled_qty',
    label: 'Filled',
    definition:
      'The portion of the order that has already executed. Will be less than Qty for partially filled orders, equal to Qty when fully done.'
  },
  filled_avg_price: {
    key: 'filled_avg_price',
    label: 'Avg Price',
    definition:
      'The volume-weighted average price across all fills on this order. For a fully filled single fill this is just the fill price; for partials or multiple fills it is the average of every executed price.'
  },
  type: {
    key: 'type',
    label: 'Type',
    definition:
      'Order type. "market" = execute immediately at the best available price. "limit" = execute only at your specified price or better. "stop" / "stop_limit" = trigger orders that become market or limit orders once a stop price is hit. Yield-paca currently places only limit orders.'
  },
  limit: {
    key: 'limit',
    label: 'Limit',
    definition:
      'A limit order: execute only at the specified limit price or better. For a buy, "better" = lower; for a sell, "better" = higher. If the market never reaches your limit, the order does not fill.'
  },
  status: {
    key: 'status',
    label: 'Status',
    definition:
      'Order lifecycle. "new" = accepted by the broker, waiting in the queue. "filled" = fully executed. "partial" = some shares/contracts filled, the rest still working. "cancelled" = you (or the system) cancelled it. "expired" = the time-in-force window passed.'
  },
  submitted_at: {
    key: 'submitted_at',
    label: 'Submitted',
    definition:
      'When the order was sent to the broker. The gap between created_at and submitted_at is the time the application spent doing risk checks and queueing.'
  },
  filled_at: {
    key: 'filled_at',
    label: 'Filled At',
    definition:
      'When the order (or the last partial fill) executed. Empty for orders that are still working or were cancelled.'
  },
  created_at: {
    key: 'created_at',
    label: 'Created',
    definition:
      'When the row was first written to the database. For an Order, that is right after the application decided to submit it (before the broker acknowledged). For a Position, that is right after the broker fill was mirrored into the local DB by AlpacaSync.'
  },
  updated_at: {
    key: 'updated_at',
    label: 'Updated',
    definition:
      'When the row was last modified. For Orders, moves on every status change (new → filled, new → expired, pending → rejected, etc.). For Positions, moves on every AlpacaSync tick that re-snapshots greeks/mark. Use it to spot stale rows vs recently-reconciled ones.'
  },
  snapshot_at: {
    key: 'snapshot_at',
    label: 'Snapshot',
    definition:
      'When the broker last quoted this position (greek refresh). Distinct from `updated_at`, which moves on ANY column change including internal bookkeeping.'
  },
  client_order_id: {
    key: 'client_order_id',
    label: 'Client Order ID',
    definition:
      'Our internal identifier for the order, generated when the application decides to submit it. Format: "pm-{trade_proposal_id}-{ticker}-{timestamp}". Used to dedupe retries and trace the order back to the proposal that created it.'
  },
  alpaca_order_id: {
    key: 'alpaca_order_id',
    label: 'Alpaca ID',
    definition:
      "The broker-side identifier returned by Alpaca. Joins the application's view of the order to the broker's view. Empty until the broker has acknowledged the order."
  },

  // ---- Position fields ----
  avg_entry_price: {
    key: 'avg_entry_price',
    label: 'Avg Entry',
    definition:
      'The average price you paid to open this position. For a single fill this is the fill price; for multiple fills or additions it is the volume-weighted average cost basis. Use this (not the most recent trade) to compute your P&L.'
  },
  market_value: {
    key: 'market_value',
    label: 'Market Value',
    definition:
      'The current dollar value of the position: Qty × current price. For options each contract is priced per share but represents 100 shares, so Market Value = Qty × option_price × 100.'
  },
  unrealized_pl: {
    key: 'unrealized_pl',
    label: 'Unrealized P&L',
    definition:
      'Profit (positive) or loss (negative) on the open position: (current price − avg_entry) × Qty × 100. Becomes "realized" the moment you close the position.'
  },
  unrealized_pl_pct: {
    key: 'unrealized_pl_pct',
    label: 'P&L %',
    definition:
      'Unrealized P&L as a percentage of the position cost basis. A quick sanity check on return versus your expectation; 50% on a $200 position is $100, 50% on a $2000 position is $1000.'
  },
  // Note: the back-end serializes this field as `unrealized_plpc`
  // (matches Alpaca's `unrealized_plpc` convention — "pc" = "percent
  // change" but the value is a fraction like 0.20, not a percent).
  // The TypeScript Position type was renamed in lockstep; this
  // glossary entry exists so the table column tooltip works either
  // way.
  unrealized_plpc: {
    key: 'unrealized_plpc',
    label: 'P&L %',
    definition:
      'Unrealized P&L as a FRACTION (e.g. 0.20 = 20% profit). Matches Alpaca\'s `unrealized_plpc` convention — the front-end multiplies by 100 for display. The position cost basis for an options contract is qty × premium × 100 (one OCC contract controls 100 shares).'
  },
  // Mid-Band Movers (and any future strategy-managed position)
  // exposes a "Plan" column on the positions table showing which
  // bucket it belongs to and when the auto-close is scheduled.
  plan: {
    key: 'plan',
    label: 'Plan',
    definition:
      'For strategy-managed positions (origin != "default"), the bucket letter and the planned sell time. Yield-paca fires each sell at `now_et + sell_at_offset_hours` via a dedicated SellWorkflow child. Default-strategy positions show "—" because their exit decision is LLM-driven, not time-driven.'
  },

  // ---- Greeks ----
  delta: {
    key: 'delta',
    label: 'Δ Delta',
    definition:
      'How much the option price moves for a $1 move in the underlying. A call with delta 0.50 gains $0.50 when the stock rises $1. A put with delta −0.50 gains $0.50 when the stock falls $1. Also approximates the probability the option expires in-the-money.'
  },
  gamma: {
    key: 'gamma',
    label: 'Γ Gamma',
    definition:
      'How fast delta changes for a $1 move in the underlying. Gamma is largest for at-the-money options near expiration. High gamma = delta moves quickly = the option is sensitive to small stock moves.'
  },
  theta: {
    key: 'theta',
    label: 'Θ Theta',
    definition:
      'Time decay: how much value the option loses per day, holding everything else constant. Always negative for long options (you bleed premium each day) and positive for short options (you collect premium each day). Accelerates near expiration.'
  },
  vega: {
    key: 'vega',
    label: 'V Vega',
    definition:
      'How much the option price moves for a 1-point change in implied volatility. A position with vega +0.50 gains $0.50 per contract if IV rises 1 point. Long options have positive vega; short options have negative vega.'
  },

  // ---- Watchlist ----
  cycle_minutes: {
    key: 'cycle_minutes',
    label: 'Cycle',
    definition:
      'How often the trading pipeline re-evaluates this ticker, in minutes. Each cycle fetches fresh market data, runs the four analyst agents, runs a bull/bear debate, and may submit a trade. Currently 5 min for most tickers.'
  },
  source: {
    key: 'source',
    label: 'Source',
    definition:
      'Where the watchlist entry came from. "manual" = you added it. "filter:{name}" = the TickerSelector workflow added it because it matched a filter (e.g. "insider_buying_cluster" for tickers with 2+ insider Form 4 buys).'
  },
  source_filter: {
    key: 'source_filter',
    label: 'Filter',
    definition:
      'The specific filter that selected this ticker. e.g. "insider_buying_cluster" = 2+ insider buys of $500k+ in the last 14 days. The full list of filters and their thresholds lives in trading.yml under the ticker_selector section.'
  },
  confidence: {
    key: 'confidence',
    label: 'Confidence',
    definition:
      "The agent's self-rated conviction in this view, on a 0–100 scale. Higher = the agent thinks this signal is more likely to play out. The ResearchManager's confidence is used as a gate: a low-confidence 'trade' verdict is treated as no_trade."
  },
  rationale: {
    key: 'rationale',
    label: 'Rationale',
    definition:
      'A short explanation of why the agent made this call. For the research manager it summarizes the bull/bear debate and the final decision.'
  },

  // ---- Order side variants (option-specific) ----
  buy_to_open: {
    key: 'buy_to_open',
    label: 'buy_to_open',
    definition:
      'Open a new long position by buying a contract. Cash leaves the account; you now own the right to exercise/sell the option.'
  },
  buy_to_close: {
    key: 'buy_to_close',
    label: 'buy_to_close',
    definition:
      'Close an existing short option position by buying it back. Realizes the P&L on the short and removes the obligation from your account.'
  },
  sell_to_open: {
    key: 'sell_to_open',
    label: 'sell_to_open',
    definition:
      'Open a new short position by writing/selling a contract. You collect the premium immediately and take on the obligation to honor the contract if assigned. Requires a higher options trading level.'
  },
  sell_to_close: {
    key: 'sell_to_close',
    label: 'sell_to_close',
    definition:
      'Close an existing long option position by selling it. Realizes the P&L on the long and frees up the buying power that was reserved.'
  },

  // ---- Strategies ----
  vertical: {
    key: 'vertical',
    label: 'Vertical',
    definition:
      'A spread with two options of the same type (both calls or both puts), same expiration, different strikes. "Bull call vertical" = long lower strike call, short higher strike call. Defined risk: max loss = net debit, max profit = spread width − net debit.'
  },
  straddle: {
    key: 'straddle',
    label: 'Straddle',
    definition:
      'Long the at-the-money call AND the at-the-money put of the same expiration. Profits on a big move in either direction; loses if the stock stays flat (both premiums decay away). Useful around earnings or known catalysts.'
  },
  strangle: {
    key: 'strangle',
    label: 'Strangle',
    definition:
      'Long an OTM call + an OTM put of the same expiration. Cheaper than a straddle (the strikes are further OTM) but needs a bigger move to pay off. Same use cases as a straddle with a wider breakeven range.'
  },
  calendar: {
    key: 'calendar',
    label: 'Calendar',
    definition:
      'A time spread: sell a near-term option, buy a longer-dated option at the same strike. Profits from the front-month decaying faster than the back-month (theta differential). Directionally neutral; works best when IV rises into the front-month expiry.'
  },
  iron_condor: {
    key: 'iron_condor',
    label: 'Iron Condor',
    definition:
      'A four-leg defined-risk options strategy: short OTM put + long further OTM put (the put spread) + short OTM call + long further OTM call (the call spread). Profits if the underlying stays inside the short strikes until expiration. Max profit = net credit, max loss = spread width − net credit.'
  },
  long_call: {
    key: 'long_call',
    label: 'Long Call',
    definition:
      'Buy a call option outright. Pays a fixed premium for unlimited upside. The simplest directional long; risk is capped at the premium paid. Used by the Mid-Band Movers strategy for every entry.'
  },
  hold: {
    key: 'hold',
    label: 'Hold',
    definition:
      'Strategy sentinel: no position is opened. The LLM either rejected the trade ("hold" in the ResearchManager verdict) or the Trader could not construct a valid proposal. Visible in the Order\'s `kind` column as `hold` for the placeholder TradeProposal row that gets written for audit.'
  },
  strategy: {
    key: 'strategy',
    label: 'Strategy',
    definition:
      "The options structure the LLM chose to express its view. 'vertical' = a two-leg spread. 'iron_condor' = a four-leg range-bound structure. 'hold' = no structure, the proposal was rejected or no_trade."
  },

  // ---- AgentRun ----
  agent_name: {
    key: 'agent_name',
    label: 'Agent',
    definition:
      'Which LLM-backed analyst or debate agent produced this run. "Analyst::MarketDataAnalyst" = price/IV/technicals, "Analyst::NewsAnalyst" = headlines, "Analyst::MacroAnalyst" = rates/VIX via FRED, "Analyst::InsiderAnalyst" = Form 4 cluster buys via SEC EDGAR, "Debate::BullResearcher" / "BearResearcher" = per-side debate, "Debate::ResearchManager" = the final gate, "Trader" = converts the plan into a concrete order.'
  },
  run_kind: {
    key: 'run_kind',
    label: 'Kind',
    definition:
      'The category of work. "analyst" = one of the four per-ticker briefs. "research" = the bull/bear debate + the research manager verdict. "trader" = the concrete order construction. "selector" = the daily ticker-selection pick.'
  },
  model_used: {
    key: 'model_used',
    label: 'Model',
    definition:
      'The LLM that produced this run (e.g. "MiniMax-M3"). Different agents can be configured to use different models; the actual provider and model are recorded here for cost/quality analysis.'
  },
  duration_ms: {
    key: 'duration_ms',
    label: 'Duration',
    definition:
      'Wall-clock time to run the agent end-to-end, including LLM latency. Useful for spotting slow paths and rate-limit waits.'
  },
  input_tokens: {
    key: 'input_tokens',
    label: 'Input Tokens',
    definition:
      'Number of tokens sent to the LLM as the prompt (the user payload + system prompt). Drives input cost on most APIs.'
  },
  output_tokens: {
    key: 'output_tokens',
    label: 'Output Tokens',
    definition:
      'Number of tokens the LLM produced as its reply. Drives output cost on most APIs (usually 3–5x more expensive per token than input).'
  },
  error_message: {
    key: 'error_message',
    label: 'Error',
    definition:
      'When the agent failed (parse error, rate limit, LLM outage), the captured error message and a hint of the cause. Empty when status is success.'
  },
  temporal_workflow_id: {
    key: 'temporal_workflow_id',
    label: 'Workflow ID',
    definition:
      'The Temporal workflow that ran this agent. Click to jump to the workflow in your Temporal UI. Format: "process-{TICKER}-{uuid}" for per-ticker pipelines.'
  },

  // ---- System concepts ----
  circuit_breaker: {
    key: 'circuit_breaker',
    label: 'Circuit Breaker',
    definition:
      'A resilience pattern: after N consecutive failures, the breaker "opens" and fast-fails subsequent calls without hitting the failing service. Periodically retries; if it succeeds the breaker "closes" and traffic resumes. Used here to stop hammering the FRED macro API after it goes down.'
  },
  rate_limit: {
    key: 'rate_limit',
    label: 'Rate Limit',
    definition:
      'A cap on how many calls per minute we send to a service (LLM, MCP, broker). Prevents a bug or hot loop from racking up API costs. When the limit is hit, calls wait in a queue with a timeout.'
  },
  iv: {
    key: 'iv',
    label: 'IV',
    definition:
      'Implied Volatility: the market\'s expectation of how much the underlying will move, annualized. Higher IV = more expensive options. Computed by inverting the Black-Scholes formula from the option\'s market price.'
  },
  iv_rank: {
    key: 'iv_rank',
    label: 'IV Rank',
    definition:
      'Where the current IV sits between the 52-week low and high IV, expressed as a percentage. IV rank 50 = IV is exactly halfway between its 52w low and high. Used to identify whether options are historically cheap (low rank) or rich (high rank).'
  },
  rsi: {
    key: 'rsi',
    label: 'RSI',
    definition:
      'Relative Strength Index: a momentum oscillator on a 0–100 scale. RSI > 70 = overbought (often a sell signal), RSI < 30 = oversold (often a buy signal). Computed from average gains vs average losses over the lookback window (default 14 days).'
  },

  // ---- Misc ----
  effective_from: {
    key: 'effective_from',
    label: 'Effective From',
    definition:
      "The first day this watchlist entry is active. Before this date the entry is not in the trading pipeline's consideration set."
  },
  tags: {
    key: 'tags',
    label: 'Tags',
    definition:
      'Free-form labels attached to a watchlist entry, e.g. "options_liquid" or "high_iv". Used by the analyst prompts to tailor their output. Configured in trading.yml under ticker_selector.tags.'
  },
  last_cycle_started_at: {
    key: 'last_cycle_started_at',
    label: 'Last Cycle',
    definition:
      'When the trading pipeline most recently started processing this ticker. If this is "stale" (e.g. 30+ minutes old) the cron is not firing or this ticker has been deprioritized.'
  },
  watchlist: {
    key: 'watchlist',
    label: 'Watchlist',
    definition:
      'The set of tickers the trading pipeline is actively considering on each cycle. The TickerSelector workflow refreshes the watchlist daily by running filters over the universe of tradeable US tickers; entries can also be added manually.'
  },

  // ---- Account panel (Dashboard) ----
  // These are the inline popovers on the AccountPanel. The component
  // used to pass them as `:fallback` props; promoting them to the
  // global glossary makes them discoverable to other screens and
  // reuses the same wording everywhere.
  account_panel: {
    key: 'account_panel',
    label: 'Alpaca Account',
    definition:
      'Live mirror of the broker account: cash, buying power, equity, open positions, and market hours. Refreshes every 30s from Alpaca via the `alpaca-mirror` Temporal schedule; the worker does NOT re-hit the broker on every UI poll.'
  },
  market_clock: {
    key: 'market_clock',
    label: 'Market clock',
    definition:
      'Live status of the US equity options market. When closed, PortfolioManager defers new orders to the next open rather than queuing them (queued orders would get rejected Monday morning). The clock is cached for 60s.'
  },
  open_positions: {
    key: 'open_positions',
    label: 'Open positions',
    definition:
      'Positions currently held at the broker. Synced from Alpaca every 30s; closed positions are auto-archived (closed_at = snapshot_at) when they drop out of the broker feed.'
  },
  open_orders: {
    key: 'open_orders',
    label: 'Open orders',
    definition:
      'Orders the system has submitted but the broker has not yet filled, partially-filled, or rejected. Refreshes every 30s; status transitions ("new" → "filled" / "partial" / "rejected") are picked up by the mirror and broadcast over ActionCable.'
  },
  pending_sync: {
    key: 'pending_sync',
    label: 'Pending sync',
    definition:
      'Orders the system submitted that the mirror has not yet seen at the broker. Should be 0 within a few seconds of submission. A persistent nonzero count means the mirror is broken or the broker rejected the order without an HTTP response.'
  },
  account_status: {
    key: 'account_status',
    label: 'Account status',
    definition:
      'The broker-side account state. ACTIVE = trading allowed. INACTIVE = account closed or restricted. Any other value (e.g. PAPER_ONLY) means the broker accepted the account but trading is blocked. "trading_blocked" surfaces as a separate flag when the broker is allowing reads but not writes.'
  },
  trading_blocked: {
    key: 'trading_blocked',
    label: 'Trading blocked',
    definition:
      'The broker is allowing account reads but rejecting new orders. Common causes: PDT (pattern day trader) rule violation, margin call, account in review. Resolve with the broker before submitting new orders.'
  },
  options_approved_level: {
    key: 'options_approved_level',
    label: 'Options level',
    definition:
      'The broker-issued options trading permission level for this account. Level 0 = options disabled. Level 1 = covered call + cash-secured put (single-leg covered writing). Level 2 = long calls/puts (any long-only options strategy). Level 3 = spreads (verticals, iron condors, strangles — but not naked writing). Level 4 = all strategies including naked writing. The Trader agent picks a strategy that fits the account\'s level; the broker rejects any order whose side is not allowed.'
  },
  multiplier: {
    key: 'multiplier',
    label: 'Margin multiplier',
    definition:
      'How much buying power you get per dollar of equity under the broker\'s margin policy. 1× = cash account (no margin), 2× = standard Reg-T margin, 4× = pattern day trader with $25k+ equity. Higher multipliers let you deploy more capital but also increase liquidation risk.'
  }
}

/**
 * Look up a glossary entry by key. Returns a fallback so unknown keys
 * still render something sensible instead of breaking the page.
 */
export function lookup(key: string): GlossaryEntry {
  const entry = GLOSSARY[key]
  if (entry) return entry
  return {
    key,
    label: key.replace(/_/g, ' '),
    definition: 'No glossary entry yet. Add one in src/glossary.ts.'
  }
}

/** All keys, useful for tests that want to assert coverage. */
export const ALL_KEYS: string[] = Object.keys(GLOSSARY)
