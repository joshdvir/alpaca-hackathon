# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_01_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "agent_runs", force: :cascade do |t|
    t.string "agent_name", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error_message"
    t.jsonb "input_payload"
    t.integer "input_tokens"
    t.string "model_used"
    t.jsonb "output_payload"
    t.integer "output_tokens"
    t.text "rationale"
    t.string "run_kind", null: false
    t.string "status", default: "pending"
    t.string "temporal_run_id"
    t.string "temporal_workflow_id"
    t.string "ticker"
    t.datetime "updated_at", null: false
    t.index ["agent_name", "ticker", "created_at"], name: "index_agent_runs_on_agent_name_and_ticker_and_created_at"
    t.index ["status"], name: "index_agent_runs_on_status"
  end

  create_table "analyst_reports", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.string "analyst_name", null: false
    t.integer "confidence"
    t.datetime "created_at", null: false
    t.string "data_freshness"
    t.jsonb "payload"
    t.text "summary"
    t.text "thesis"
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_analyst_reports_on_agent_run_id"
    t.index ["analyst_name", "ticker", "created_at"], name: "idx_on_analyst_name_ticker_created_at_14b199f9e2"
    t.index ["ticker", "confidence"], name: "index_analyst_reports_on_ticker_and_confidence"
  end

  create_table "backtest_runs", force: :cascade do |t|
    t.jsonb "config_snapshot"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.decimal "final_equity"
    t.datetime "finished_at"
    t.decimal "max_drawdown"
    t.string "mode", default: "full"
    t.integer "period_days"
    t.decimal "sharpe"
    t.decimal "start_of_day_equity"
    t.datetime "started_at"
    t.string "status", default: "running"
    t.string "temporal_run_id"
    t.string "temporal_workflow_id"
    t.string "tickers", default: [], array: true
    t.decimal "total_pnl"
    t.integer "total_trades", default: 0
    t.datetime "updated_at", null: false
    t.integer "winning_trades", default: 0
    t.index ["status"], name: "index_backtest_runs_on_status"
    t.index ["temporal_workflow_id"], name: "index_backtest_runs_on_temporal_workflow_id"
  end

  create_table "backtest_trades", force: :cascade do |t|
    t.bigint "backtest_run_id", null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.decimal "entry_price"
    t.decimal "exit_price"
    t.jsonb "legs"
    t.datetime "opened_at"
    t.decimal "pnl"
    t.string "strategy_type"
    t.string "ticker"
    t.datetime "updated_at", null: false
    t.index ["backtest_run_id", "ticker"], name: "index_backtest_trades_on_backtest_run_id_and_ticker"
    t.index ["backtest_run_id"], name: "index_backtest_trades_on_backtest_run_id"
  end

  create_table "bear_cases", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.integer "confidence"
    t.datetime "created_at", null: false
    t.text "narrative"
    t.jsonb "payload"
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_bear_cases_on_agent_run_id"
    t.index ["ticker", "created_at"], name: "index_bear_cases_on_ticker_and_created_at"
  end

  create_table "bull_cases", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.integer "confidence"
    t.datetime "created_at", null: false
    t.text "narrative"
    t.jsonb "payload"
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_bull_cases_on_agent_run_id"
    t.index ["ticker", "created_at"], name: "index_bull_cases_on_ticker_and_created_at"
  end

  create_table "fills", force: :cascade do |t|
    t.string "alpaca_fill_id"
    t.datetime "created_at", null: false
    t.datetime "filled_at", null: false
    t.bigint "order_id", null: false
    t.decimal "price", null: false
    t.integer "qty", null: false
    t.datetime "updated_at", null: false
    t.index ["alpaca_fill_id"], name: "index_fills_on_alpaca_fill_id", unique: true, where: "(alpaca_fill_id IS NOT NULL)"
    t.index ["order_id"], name: "index_fills_on_order_id"
  end

  create_table "insider_transactions", force: :cascade do |t|
    t.string "accession_number"
    t.datetime "created_at", null: false
    t.string "filer_name"
    t.string "filer_relationship"
    t.decimal "price_per_share"
    t.decimal "shares"
    t.string "ticker", null: false
    t.decimal "total_value"
    t.string "transaction_code"
    t.date "transaction_date"
    t.datetime "updated_at", null: false
    t.index ["ticker", "transaction_date"], name: "index_insider_transactions_on_ticker_and_transaction_date"
  end

  create_table "macro_indicators", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "observed_on", null: false
    t.string "series_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "value"
    t.index ["series_id", "observed_on"], name: "index_macro_indicators_on_series_id_and_observed_on", unique: true
  end

  create_table "market_snapshots", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.datetime "created_at", null: false
    t.string "data_type", null: false
    t.jsonb "payload", null: false
    t.string "symbol", null: false
    t.datetime "updated_at", null: false
    t.index ["symbol", "data_type", "captured_at"], name: "index_market_snapshots_on_symbol_and_data_type_and_captured_at"
  end

  create_table "news_items", force: :cascade do |t|
    t.string "alpaca_news_id", null: false
    t.datetime "created_at", null: false
    t.string "headline"
    t.datetime "published_at"
    t.string "source"
    t.text "summary"
    t.jsonb "symbols"
    t.datetime "updated_at", null: false
    t.index ["alpaca_news_id"], name: "index_news_items_on_alpaca_news_id", unique: true
    t.index ["published_at"], name: "index_news_items_on_published_at"
  end

  create_table "orders", force: :cascade do |t|
    t.string "alpaca_order_id"
    t.string "client_order_id", null: false
    t.datetime "created_at", null: false
    t.datetime "filled_at"
    t.decimal "filled_avg_price"
    t.integer "filled_qty", default: 0
    t.integer "qty", null: false
    t.jsonb "raw_response"
    t.string "rejection_reason"
    t.string "side", null: false
    t.string "status", default: "new", null: false
    t.datetime "submitted_at"
    t.string "symbol", null: false
    t.bigint "trade_proposal_id"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["alpaca_order_id"], name: "index_orders_on_alpaca_order_id", unique: true, where: "(alpaca_order_id IS NOT NULL)"
    t.index ["client_order_id"], name: "index_orders_on_client_order_id", unique: true
    t.index ["rejection_reason"], name: "index_orders_on_rejection_reason_present", where: "(rejection_reason IS NOT NULL)"
    t.index ["status"], name: "index_orders_on_status"
    t.index ["trade_proposal_id"], name: "index_orders_on_trade_proposal_id"
  end

  create_table "portfolio_snapshots", force: :cascade do |t|
    t.decimal "buying_power"
    t.decimal "cash"
    t.datetime "created_at", null: false
    t.decimal "daily_pl"
    t.decimal "equity"
    t.decimal "options_buying_power"
    t.jsonb "raw"
    t.decimal "total_pl"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_portfolio_snapshots_on_created_at"
  end

  create_table "position_reviews", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.decimal "current_iv_vs_entry"
    t.decimal "delta_drift"
    t.jsonb "new_legs"
    t.text "rationale"
    t.string "recommendation", null: false
    t.string "status", default: "pending"
    t.text "thesis_evolution"
    t.boolean "thesis_still_valid"
    t.string "ticker", null: false
    t.decimal "time_decay_consumed_pct"
    t.bigint "trade_proposal_id", null: false
    t.string "trigger", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_position_reviews_on_agent_run_id"
    t.index ["ticker", "created_at"], name: "index_position_reviews_on_ticker_and_created_at"
    t.index ["trade_proposal_id"], name: "index_position_reviews_on_trade_proposal_id"
  end

  create_table "positions", force: :cascade do |t|
    t.string "asset_class", default: "us_option"
    t.decimal "avg_entry_price"
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.decimal "delta"
    t.decimal "gamma"
    t.integer "hold_streak", default: 0, null: false
    t.decimal "market_value"
    t.string "origin", default: "default", null: false
    t.datetime "planned_sell_at"
    t.integer "qty"
    t.jsonb "raw"
    t.datetime "snapshot_at", null: false
    t.string "strategy_bucket"
    t.string "symbol", null: false
    t.decimal "theta"
    t.decimal "unrealized_pl"
    t.datetime "updated_at", null: false
    t.decimal "vega"
    t.index ["closed_at"], name: "index_positions_on_closed_at"
    t.index ["hold_streak"], name: "index_positions_on_hold_streak"
    t.index ["origin"], name: "index_positions_on_origin"
    t.index ["planned_sell_at"], name: "index_positions_on_planned_sell_at"
    t.index ["symbol", "snapshot_at"], name: "index_positions_on_symbol_and_snapshot_at"
  end

  create_table "research_plans", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.integer "confidence"
    t.datetime "created_at", null: false
    t.jsonb "invalidation_conditions"
    t.jsonb "key_catalysts"
    t.string "recommendation", null: false
    t.text "synthesis"
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_until", null: false
    t.index ["agent_run_id"], name: "index_research_plans_on_agent_run_id"
    t.index ["ticker", "created_at"], name: "index_research_plans_on_ticker_and_created_at"
    t.index ["valid_until"], name: "index_research_plans_on_valid_until"
  end

  create_table "risk_decisions", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.jsonb "limit_snapshot"
    t.text "reasons"
    t.bigint "trade_proposal_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_risk_decisions_on_agent_run_id"
    t.index ["decision"], name: "index_risk_decisions_on_decision"
    t.index ["trade_proposal_id"], name: "index_risk_decisions_on_trade_proposal_id"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "tool_calls", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.jsonb "arguments"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.integer "http_status"
    t.jsonb "result_summary"
    t.integer "retry_count", default: 0
    t.string "source"
    t.string "status", default: "success"
    t.string "tool_name", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_tool_calls_on_agent_run_id"
    t.index ["created_at"], name: "index_tool_calls_on_created_at"
    t.index ["source"], name: "index_tool_calls_on_source"
    t.index ["status"], name: "index_tool_calls_on_status"
  end

  create_table "trade_proposals", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.bigint "closes_position_id"
    t.datetime "created_at", null: false
    t.string "kind", default: "new", null: false
    t.jsonb "legs", null: false
    t.decimal "max_loss"
    t.decimal "max_profit"
    t.string "origin", default: "default", null: false
    t.text "rationale"
    t.text "rejection_reason"
    t.bigint "research_plan_id"
    t.string "status", default: "pending"
    t.string "strategy_type", null: false
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_trade_proposals_on_agent_run_id"
    t.index ["closes_position_id"], name: "index_trade_proposals_on_closes_position_id"
    t.index ["kind"], name: "index_trade_proposals_on_kind"
    t.index ["origin"], name: "index_trade_proposals_on_origin"
    t.index ["research_plan_id"], name: "index_trade_proposals_on_research_plan_id"
    t.index ["ticker", "status", "created_at"], name: "index_trade_proposals_on_ticker_and_status_and_created_at"
  end

  create_table "watchlist_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "cycle_minutes", default: 15, null: false
    t.date "effective_from", null: false
    t.date "effective_until"
    t.datetime "last_cycle_started_at"
    t.string "last_temporal_run_id"
    t.string "source", null: false
    t.jsonb "tags"
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["effective_until"], name: "index_watchlist_entries_on_effective_until"
    t.index ["ticker", "effective_from"], name: "index_watchlist_entries_on_ticker_and_effective_from"
    t.index ["ticker"], name: "idx_active_watchlist_ticker", where: "(effective_until IS NULL)"
  end

  create_table "watchlist_recommendations", force: :cascade do |t|
    t.decimal "confidence"
    t.datetime "created_at", null: false
    t.text "rationale"
    t.date "recommended_on", null: false
    t.jsonb "scores"
    t.string "source_filter", null: false
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["recommended_on"], name: "index_watchlist_recommendations_on_recommended_on"
    t.index ["ticker", "recommended_on"], name: "index_watchlist_recommendations_on_ticker_and_recommended_on", unique: true
  end

  add_foreign_key "analyst_reports", "agent_runs"
  add_foreign_key "backtest_trades", "backtest_runs"
  add_foreign_key "bear_cases", "agent_runs"
  add_foreign_key "bull_cases", "agent_runs"
  add_foreign_key "fills", "orders"
  add_foreign_key "orders", "trade_proposals"
  add_foreign_key "position_reviews", "agent_runs"
  add_foreign_key "position_reviews", "trade_proposals"
  add_foreign_key "research_plans", "agent_runs"
  add_foreign_key "risk_decisions", "agent_runs"
  add_foreign_key "risk_decisions", "trade_proposals"
  add_foreign_key "tool_calls", "agent_runs"
  add_foreign_key "trade_proposals", "agent_runs"
  add_foreign_key "trade_proposals", "positions", column: "closes_position_id"
  add_foreign_key "trade_proposals", "research_plans"
end
