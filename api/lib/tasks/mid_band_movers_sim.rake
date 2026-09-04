# frozen_string_literal: true

# mid_band_movers:dry_run — runs the Mid-Band Movers planning pipeline
# end-to-end without hitting the broker or submitting any orders.
#
# Use this to:
#   - See what the strategy would buy on a given day
#   - Debug why a real run produced an empty plan
#   - Replay the strategy against a fixed mock data set (--mock)
#
# By default the task pulls the live optionable universe + market
# movers from the Alpaca MCP and runs Strategy.plan against the
# latest PortfolioSnapshot. Pass --mock to skip MCP and use a
# canned 50-name set (handy when the broker is rate-limiting or
# the market is closed).
#
# Examples:
#   bin/rails mid_band_movers:dry_run                  # live data
#   bin/rails mid_band_movers:dry_run --mock          # canned data
#   bin/rails mid_band_movers:dry_run --buying-power=20000  # override BP
#   bin/rails mid_band_movers:dry_run --verbose       # full order details

namespace :mid_band_movers do
  desc "Run the Mid-Band Movers planning pipeline end-to-end (no orders submitted)"
  task dry_run: :environment do
    require Rails.root.join("app/strategies/mid_band_movers/plan").to_s
    require Rails.root.join("app/strategies/mid_band_movers/strategy").to_s

    cfg = (TradingConfig.fetch(:mid_band_movers) || {}).deep_stringify_keys
    verbose = ENV["VERBOSE"] == "1" || ENV["verbose"] == "true"

    bp_override = ENV["BUYING_POWER"] || ENV["buying_power"]
    now = Time.current.in_time_zone("America/New_York")

    puts ""
    puts "=" * 70
    puts "Mid-Band Movers dry run  (#{now.strftime("%Y-%m-%d %H:%M:%S %Z")})"
    puts "=" * 70
    puts "Config: drop_top_pct=#{cfg.dig('middle_band', 'drop_top_pct')}% " \
         "drop_bottom_pct=#{cfg.dig('middle_band', 'drop_bottom_pct')}% " \
         "total_risk_pct=#{(cfg['total_risk_pct'].to_f * 100).round(1)}% " \
         "universe_top_n=#{cfg['universe_top_n']} " \
         "dte_target=#{cfg['dte_target']}"
    puts ""

    if ENV["MOCK"] == "1" || ENV["mock"] == "true"
      universe, movers = mock_data
      bp = bp_override ? BigDecimal(bp_override) : BigDecimal("10000")
      puts "Source: MOCK (50 universe, 50 movers, BP=$#{bp.to_i})"
    else
      universe = fetch_live_universe(cfg)
      movers   = fetch_live_movers(cfg)
      bp       = bp_override ? BigDecimal(bp_override) : fetch_live_bp
      puts "Source: LIVE MCP (universe=#{universe.size} movers=#{movers.size} BP=$#{bp.to_f.round(2)})"
    end
    puts ""

    plan = MidBandMovers::Strategy.plan(
      optionable_universe: universe,
      movers: movers,
      options_buying_power: bp,
      cfg: cfg,
      now: now
    )

    total_kept = plan.a.ticker_count + plan.b.ticker_count + plan.c.ticker_count
    puts "Plan summary"
    puts "  kept:       #{total_kept} of #{movers.size} movers (#{cfg.dig('middle_band', 'drop_top_pct')}% top / #{cfg.dig('middle_band', 'drop_bottom_pct')}% bottom dropped)"
    puts "  deployed:   $#{plan.total_cash_deployed.to_f.round(2)}  (target = 35% of $#{bp.to_f.round(2)} = $#{(bp.to_f * 0.35).round(2)})"
    puts "  tick_date:  #{plan.tick_date}"
    puts ""

    %w[a b c].each do |bucket_key|
      bucket = plan.public_send(bucket_key)
      puts "  Bucket #{bucket.name}  (#{bucket.orders.size} tickers, hold #{bucket.hold_hours}h, sell at +#{bucket.sell_at_offset_hours}h)"
      if bucket.orders.empty?
        puts "    (no orders)"
      else
        bucket.orders.each do |order|
          if verbose
            puts "    - #{order.symbol.ljust(8)} $#{order.cash_allocated.to_f.round(2)}"
          else
            print "    - #{order.symbol.ljust(8)} $#{order.cash_allocated.to_f.round(2).to_s.rjust(8)}"
            puts "  (target ATM #{cfg['dte_target']}DTE call, qty = floor($#{order.cash_allocated.to_f.round(2)} / (premium * 100)))"
          end
        end
      end
    end
    puts ""

    if total_kept.zero?
      puts "No orders. The strategy will not submit anything this run."
      puts "Common reasons:"
      puts "  - Market closed (run during 9:30 AM - 4:00 PM ET for live movers)"
      puts "  - get_market_movers returned fewer than 5 names"
      puts "  - None of the top movers are in the optionable universe"
      puts "Try --mock to see the strategy plan against canned data."
    end
  end

  # --- helpers ---

  # Canned 50-name mock data set. 50 of these are in the universe;
  # the same 50 are returned as movers, so the filter passes all
  # of them. Use this to demo the strategy end-to-end without
  # needing a live broker.
  def self.mock_data
    symbols = %w[
      AAPL MSFT NVDA GOOGL META AMZN TSLA JPM V UNH XOM CVX LLY
      AVGO COST WMT PG HD MA BAC ABT ACN ADBE NFLX CRM ORCL
      AMD INTC QCOM TXN IBM CSCO NOW INTU SNPS ADI PANW KLAC
      MRNA PYPL TMO MDT DHR LIN SYK REGN VRTX GILD BDX
    ].uniq
    universe = symbols.map { |s| { "symbol" => s, "attributes" => ["has_options"] } }
    movers = symbols.each_with_index.map do |s, i|
      {
        "symbol" => s,
        "price" => 100.0,
        "change" => (50 - i) * 0.5,
        "percent_change" => 10.0 - (i * 0.15) # TKR0 = +10%, TKR49 = +2.5%
      }
    end
    [universe, movers]
  end

  def self.fetch_live_universe(cfg)
    cache_key = "mbm:optionable_universe:v1"
    cached = Rails.cache.read(cache_key)
    if cached
      puts "(using cached optionable universe: #{cached.size} names)"
      return cached
    end
    tool = ALPACA_MCP_READONLY.tool("get_all_assets")
    return [] unless tool

    raw = tool.call(asset_class: "us_equity", status: "active", attributes: ["has_options"])
    parsed = Mcp::Response.unwrap(raw, tool_name: "get_all_assets") || []
    cap = (cfg["universe_top_n"] || 500).to_i
    assets = parsed.first(cap)
    Rails.cache.write(cache_key, assets, expires_in: 15.minutes)
    assets
  end

  def self.fetch_live_movers(cfg)
    n = (cfg["universe_top_n"] || 50).to_i
    tool = ALPACA_MCP_READONLY.tool("get_market_movers")
    return [] unless tool

    raw = tool.call(market_type: "stocks", top: n)
    Mcp::Response.unwrap(raw, tool_name: "get_market_movers") || []
  end

  def self.fetch_live_bp
    PortfolioSnapshot.recent.first&.options_buying_power.to_d || 0
  end
end
