# frozen_string_literal: true

# AlpacaSync — keeps our DB in sync with the broker's view of the
# world. Single entry point for the AlpacaMirrorJob.
#
# Three responsibilities:
#
#   1. sync_account_snapshot
#        Pull `get_account_info` and write a PortfolioSnapshot row.
#        The dashboard reads this row to show cash / buying power /
#        equity. We keep a time-series (one row per sync) so we can
#        chart equity over time later.
#
#   2. sync_positions
#        Pull `get_all_positions` and upsert into the Position table.
#        "Mirror" because Alpaca is the source of truth — if a fill
#        happened via a different process, manual close, or
#        assignment, the mirror reflects that within 30s.
#
#   3. sync_orders
#        Pull `get_orders` and update our Order rows. Catches:
#          - broker fills (status transitions: new/partial → filled)
#          - broker rejects (we never got an order id; this would
#            have been caught by PortfolioManager already, but this
#            is the safety net)
#          - broker cancels / expires
#        On a fill transition, creates a Position row so the
#        MonitorPositionWorkflow has something to monitor.
#
# All three are safe to call concurrently. We use the trading MCP
# client (read-only tools are also on it). Each method returns a
# Result struct so the calling job can log what happened.

class AlpacaSync
  Result = Data.define(:ok, :synced, :errors, :snapshot_id) do
    def ok? = ok
    def summary
      "synced=#{synced} errors=#{errors.size}"
    end
  end

  def self.sync_account_snapshot
    new.sync_account_snapshot
  end

  def self.sync_positions
    new.sync_positions
  end

  def self.sync_orders
    new.sync_orders
  end

  def self.sync_all
    # Run sequentially so a single failure doesn't poison the others.
    # The 3 calls together take ~1-2s against paper.
    acct = sync_account_snapshot
    pos  = sync_positions
    ords = sync_orders
    # Self-heal: for any open position, make sure the monitor +
    # review workflows are running. Done AFTER the position sync so
    # the latest qty / Greeks are available to the workflows. Catches
    # fills that happened before this code shipped and any case where
    # T_CLIENT was briefly unavailable on the original fill.
    new.send(:ensure_position_workflows_running)
    {
      account: acct,
      positions: pos,
      orders: ords
    }
  end

  def sync_account_snapshot
    raw = call_mcp("get_account_info")
    return Result.new(ok: false, synced: 0, errors: ["get_account_info: #{raw[:error]}"], snapshot_id: nil) unless raw[:ok]

    # `get_account_info` returns the account dict directly (no
    # `result` wrapper), so `raw[:data]` is the account fields.
    data = raw[:data] || {}
    snap = PortfolioSnapshot.create!(
      equity:               data["equity"],
      cash:                 data["cash"],
      buying_power:         data["buying_power"],
      options_buying_power: data["options_buying_power"],
      daily_pl:             data["equity"].to_f - data["last_equity"].to_f,
      total_pl:             nil, # not provided by get_account_info
      raw:                  data
    )
    Result.new(ok: true, synced: 1, errors: [], snapshot_id: snap.id)
  rescue StandardError => e
    Rails.logger.error "[alpaca_sync] account sync failed: #{e.class}: #{e.message}"
    Result.new(ok: false, synced: 0, errors: ["#{e.class}: #{e.message}"], snapshot_id: nil)
  end

  def sync_positions
    raw = call_mcp("get_all_positions")
    return Result.new(ok: false, synced: 0, errors: ["get_all_positions: #{raw[:error]}"], snapshot_id: nil) unless raw[:ok]

    # `get_all_positions` returns { data: { result: [ {...}, ... ] } }.
    data = raw[:data] || []
    synced = 0

    # If Alpaca has zero positions, mark any open DB positions as
    # closed (snapshot_at = now) so the front-end shows a clean
    # zero state. This catches manual closes done outside the system.
    if data.empty?
      Position.open.find_each do |p|
        p.update!(closed_at: Time.current, snapshot_at: Time.current)
        synced += 1
      end
      return Result.new(ok: true, synced: synced, errors: [], snapshot_id: nil)
    end

    now = Time.current
    seen_symbols = []

    data.each do |p|
      sym = p["symbol"] or next
      seen_symbols << sym
      attrs = {
        symbol:        sym,
        asset_class:   p["asset_class"] || "us_option",
        qty:           p["qty"].to_i,
        avg_entry_price: p["avg_entry_price"],
        market_value:  p["market_value"],
        unrealized_pl: p["unrealized_pl"],
        snapshot_at:   now,
        raw:           p
      }
      existing = Position.open.where(symbol: sym).order(snapshot_at: :desc).first
      if existing
        existing.update!(attrs)
        synced += 1
      else
        position = Position.create!(attrs)
        # Backfill strategy metadata from the most recent Order's
        # raw_response payload. The Mid-Band Movers strategy stashes
        # `mbm_origin`, `mbm_strategy_bucket`, and `mbm_planned_sell_at`
        # on the Order when the buy is submitted (see
        # SubmitBuyOrdersActivity#tag_order_with_plan_metadata). When
        # the broker reports the fill and AlpacaSync materializes the
        # Position here, the strategy columns are still nil — backfill
        # them so the open-positions UI shows the Plan column
        # immediately, instead of waiting until the SellWorkflow
        # runs at the planned sell time.
        backfill_strategy_metadata!(position)
        synced += 1
      end
    end

    # Any open DB position that doesn't appear in the broker feed
    # was closed (manually, or via a different process). Mark it
    # closed with snapshot_at = now so it stops showing in open view.
    Position.open.where.not(symbol: seen_symbols).find_each do |p|
      p.update!(closed_at: now, snapshot_at: now)
      synced += 1
    end

    Result.new(ok: true, synced: synced, errors: [], snapshot_id: nil)
  rescue StandardError => e
    Rails.logger.error "[alpaca_sync] positions sync failed: #{e.class}: #{e.message}"
    Result.new(ok: false, synced: 0, errors: ["#{e.class}: #{e.message}"], snapshot_id: nil)
  end

  def sync_orders
    raw = call_mcp("get_orders", { status: "all", limit: 200 })
    return Result.new(ok: false, synced: 0, errors: ["get_orders: #{raw[:error]}"], snapshot_id: nil) unless raw[:ok]

    # `get_orders` returns { data: { result: [ {...}, ... ] } }
    data = raw[:data] || []
    synced = 0
    errors = []

    data.each do |o|
      broker_id = o["id"]
      next if broker_id.blank?

      # Find our Order row by broker id (preferred) or by
      # client_order_id (broker echoes it back in `client_order_id`
      # for orders we submitted).
      our_order = Order.find_by(alpaca_order_id: broker_id)
      our_order ||= Order.find_by(client_order_id: o["client_order_id"]) if o["client_order_id"].present?
      next unless our_order

      updates = {
        status:        map_broker_status(o["status"]),
        filled_qty:    (o["filled_qty"] || 0).to_i,
        filled_avg_price: o["filled_avg_price"]
      }
      updates[:submitted_at] = Time.parse(o["submitted_at"]) if o["submitted_at"].present? && our_order.submitted_at.nil?
      updates[:filled_at]    = Time.parse(o["filled_at"])    if o["filled_at"].present?    && our_order.filled_at.nil?
      updates[:rejection_reason] = o["rejected_reason"] if o["rejected_reason"].present?

      our_order.update!(updates)

      # On a fresh fill, record the fill + create a Position mirror.
      if our_order.saved_change_to_status? && our_order.status == "filled"
        create_fill_record(our_order, o)
        ensure_position_for_fill(our_order, o)
      end

      synced += 1
    rescue StandardError => e
      errors << "order #{broker_id}: #{e.class}: #{e.message[0,200]}"
    end

    Result.new(ok: errors.empty?, synced: synced, errors: errors, snapshot_id: nil)
  end

  private

  # Single call helper. Wraps the MCP client, rate limiter, and
  # circuit breaker so every call goes through them. Returns either
  # {ok: true, data: ...} or {ok: false, error: "..."}.
  def call_mcp(tool_name, args = {})
    tool = ALPACA_MCP_TRADING.tool(tool_name)
    return { ok: false, error: "tool '#{tool_name}' not found on ALPACA_MCP_TRADING" } if tool.nil?

    raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
      CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(args) }
    end

    parsed = unwrap(raw)
    if parsed.is_a?(Hash) && parsed["error"].is_a?(Hash)
      err = parsed["error"]
      msg = err["message"].to_s
      detail = err["detail"]
      if detail.is_a?(Hash)
        msg = "#{msg} (#{detail['message']})" if detail["message"].present?
      end
      { ok: false, error: msg }
    elsif parsed.is_a?(Hash) && parsed["data"].is_a?(Hash) && parsed["data"].key?("result")
      # `get_orders` / `get_all_positions` return { data: { result: [...] } }.
      # `result` is the actual payload (array for lists, hash for single
      # objects) — return it as-is.
      { ok: true, data: parsed["data"]["result"] }
    elsif parsed.is_a?(Hash) && parsed["data"].is_a?(Hash)
      # `get_account_info` / `get_clock` / `get_account_config` return
      # the payload directly under `data` (no `result` wrapper).
      { ok: true, data: parsed["data"] }
    elsif parsed.is_a?(Hash) && parsed["data"]
      { ok: true, data: parsed["data"] }
    else
      { ok: true, data: parsed }
    end
  rescue StandardError => e
    Rails.logger.warn "[alpaca_sync] #{tool_name} call failed: #{e.class}: #{e.message[0,200]}"
    { ok: false, error: "#{e.class}: #{e.message[0,200]}" }
  end

  def unwrap(raw)
    text = if raw.is_a?(Array)
             raw.first&.respond_to?(:text) ? raw.first.text : raw.first.to_s
           elsif raw.respond_to?(:text)
             raw.text
           else
             raw.to_s
           end
    JSON.parse(text.to_s)
  rescue JSON::ParserError
    {}
  end

  def map_broker_status(s)
    case s.to_s
    when "filled" then "filled"
    when "partially_filled", "partial" then "partial"
    when "canceled", "cancelled" then "cancelled"
    when "expired" then "expired"
    when "rejected" then "rejected"
    when "new", "accepted", "pending_new", "accepted_for_bidding" then "new"
    else "new"
    end
  end

  # The broker response includes a `filled_qty` and `filled_avg_price`
  # but NOT individual fill records. We synthesize one Fill row
  # representing the entire fill. The downstream `fills` table tracks
  # per-fill audit; this is enough to trigger the Position mirror.
  def create_fill_record(order, broker_order)
    return if broker_order["filled_qty"].to_i.zero?

    fill_qty = broker_order["filled_qty"].to_i
    price    = broker_order["filled_avg_price"]
    return if price.nil?

    existing_qty = order.fills.sum(:qty)
    return if existing_qty >= fill_qty # already recorded

    Fill.create!(
      order:       order,
      filled_at:   (broker_order["filled_at"].present? ? Time.parse(broker_order["filled_at"]) : Time.current),
      price:       price,
      qty:         fill_qty - existing_qty,
      alpaca_fill_id: broker_order["id"].present? ? "broker-#{broker_order['id']}-#{existing_qty}" : nil
    )
  end

  def ensure_position_for_fill(order, broker_order)
    return if broker_order["filled_qty"].to_i.zero?

    sym = order.symbol
    return if sym.blank?

    # Upsert a Position mirror so the front-end shows the live
    # position and MonitorPositionWorkflow can attach.
    qty = broker_order["filled_qty"].to_i
    qty = order.side.start_with?("buy") ? qty : -qty
    side_qty = qty.abs

    existing = Position.open.where(symbol: sym).order(snapshot_at: :desc).first
    if existing
      existing.update!(
        qty:             side_qty,
        avg_entry_price: broker_order["filled_avg_price"],
        market_value:    nil, # refreshed by the next position sync
        snapshot_at:     Time.current
      )
      false
    else
      position = Position.create!(
        symbol:          sym,
        asset_class:     "us_option",
        qty:             side_qty,
        avg_entry_price: broker_order["filled_avg_price"],
        snapshot_at:     Time.current
      )
      # First time we've seen this position — kick off the
      # monitor workflow so the position gets checked within
      # the next minute. The review workflow is driven by the
      # `position-review-all` Temporal schedule (every 30 min),
      # so the new position will be picked up on the next tick.
      # The monitor workflow ID includes a timestamp suffix, so
      # a re-fill on the same symbol won't spawn duplicates.
      start_position_workflows(position)
      true
    end
  end

  # Start the monitor (1-min one-shot) workflow for a position.
  # Used both on first-fill (via ensure_position_for_fill) and on
  # self-heal (via ensure_position_workflows_running, called every
  # mirror tick).
  #
  # The monitor workflow is ONE-SHOT (no internal loop) — each tick
  # creates a new workflow execution with a unique ID
  # (`monitor-<position_id>-<timestamp_ms>`). The mirror's self-heal
  # IS the implicit scheduler, so this method is called once per
  # mirror tick per position, which produces one workflow execution
  # per minute per position. This keeps Temporal history bounded and
  # makes each tick independently observable in the UI.
  #
  # The review workflow is NOT started here — it's driven by the
  # `position-review-all` Temporal schedule (every 30 min), which
  # spawns one parented child per open position. The schedule picks
  # up new positions on the next tick (within 30 min of a fill),
  # which is acceptable for a 30-min review cadence.
  #
  # Wrapped in begin/rescue so a Temporal hiccup (network blip,
  # circuit open, etc.) doesn't fail the mirror sync. The workflow
  # can be re-attempted on the next sync tick.
  def start_position_workflows(position)
    return if position.blank?
    return unless defined?(T_CLIENT) && T_CLIENT

    # Suffix the workflow ID with millisecond timestamp so each call
    # creates a fresh execution (one-shot monitor, not long-running).
    monitor_id = "monitor-#{position.id}-#{Time.now.to_f.to_s.tr('.', '')}"

    T_CLIENT.start_workflow(
      Positions::MonitorPositionWorkflow,
      position.id,
      id: monitor_id,
      task_queue: 'position-queue',
      retry_policy: T_RETRY_POLICY
    )
  end

  # Backfill strategy-managed metadata (origin, strategy_bucket,
  # planned_sell_at) onto a newly-materialized Position. The
  # Mid-Band Movers strategy stashes these on the Order's
  # raw_response payload when the buy is submitted (see
  # SubmitBuyOrdersActivity#tag_order_with_plan_metadata). When
  # the broker reports the fill and we create the Position row
  # here, those columns are still nil. Backfill them now so the
  # open-positions UI shows the Plan column immediately instead
  # of waiting for the SellWorkflow to do it at the planned sell
  # time (which may be hours later for bucket C).
  #
  # Idempotent: if the position already has the metadata (e.g.
  # the SellWorkflow or FindMbmPositionActivity got there first),
  # the update is a no-op.
  def backfill_strategy_metadata!(position)
    return if position.nil?
    return if position.origin != 'default' # already backfilled or strategy-set
    return if position.strategy_bucket.present? && position.planned_sell_at.present?

    # Look up the most recent Order for this symbol. Prefer OVN matches
    # (which carry the close-time-managed bucket) over MBM. We try OVN
    # first because `ovn_bucket` is the only field the close child
    # reads back — without it the position is invisible to the close
    # workflow at 15:55 ET.
    order =
      ::Order.where(symbol: position.symbol)
             .where("raw_response ->> 'ovn_origin' = ?", 'overnight_reversal')
             .order(created_at: :desc)
             .first ||
      ::Order.where(symbol: position.symbol)
             .where("raw_response ->> 'mbm_origin' = ?", 'mid_band_movers')
             .order(created_at: :desc)
             .first
    return if order.nil? || !order.raw_response.is_a?(Hash)

    raw = order.raw_response

    # ── overnight_reversal ──
    if raw['ovn_origin'] == 'overnight_reversal'
      # Spread legs come in as two separate OCC symbols on the broker.
      # The Order row uses a comma-joined symbol (`occ,occ`), so the
      # backfill can't directly match a single-leg Position row. Skip
      # — multi-leg spread positions are tracked separately via the
      # raw `ovn_bucket` if they ever need closing. The bare long_call
      # fallback legs (BDRY/BABO/ALTY) and the winner long_calls DO
      # match by symbol and get backfilled here.
      return if order.symbol.to_s.include?(',') # multi-leg spread, no single Position row

      bucket = raw['ovn_bucket']
      return unless %w[winner loser].include?(bucket)
      updates = { origin: 'overnight_reversal', strategy_bucket: bucket }
      position.update!(updates)
      Rails.logger.info "[alpaca_sync] backfilled ovn metadata position=#{position.id} bucket=#{bucket}"
      return
    end

    # ── mid_band_movers ──
    return unless raw['mbm_origin'] == 'mid_band_movers'

    updates = { origin: 'mid_band_movers' }
    updates[:strategy_bucket]  = raw['mbm_strategy_bucket']  if raw['mbm_strategy_bucket'].present?  && position.strategy_bucket.nil?
    updates[:planned_sell_at] = (Time.iso8601(raw['mbm_planned_sell_at']) if raw['mbm_planned_sell_at'].present?) if position.planned_sell_at.nil?

    position.update!(updates)
    Rails.logger.info "[alpaca_sync] backfilled strategy metadata position=#{position.id} bucket=#{updates[:strategy_bucket]} planned_sell_at=#{updates[:planned_sell_at]&.iso8601}"
  rescue StandardError => e
    # Backfill is a best-effort convenience. A failure here must NOT
    # block the position sync — the SellWorkflow will retry the
    # backfill at sell time. Log and move on.
    Rails.logger.warn "[alpaca_sync] backfill failed for position=#{position&.id}: #{e.class}: #{e.message}"
  end

  def start_position_workflows(position)
    return if position.blank?
    return unless defined?(T_CLIENT) && T_CLIENT

    # Suffix the workflow ID with millisecond timestamp so each call
    # creates a fresh execution (one-shot monitor, not long-running).
    monitor_id = "monitor-#{position.id}-#{Time.now.to_f.to_s.tr('.', '')}"

    T_CLIENT.start_workflow(
      Positions::MonitorPositionWorkflow,
      position.id,
      id: monitor_id,
      task_queue: 'position-queue',
      retry_policy: T_RETRY_POLICY
    )
    Rails.logger.info "[alpaca_sync] started MonitorPositionWorkflow for position=#{position.id} (id=#{monitor_id})"
  rescue Temporalio::Error::WorkflowAlreadyStartedError
    # Already running — fine (shouldn't happen with timestamp IDs but
    # keep the rescue as a safety net).
  rescue StandardError => e
    Rails.logger.warn "[alpaca_sync] failed to start MonitorPositionWorkflow for position=#{position.id}: #{e.class}: #{e.message[0, 200]}"
  end

  # Self-heal: for each open position, make sure the monitor
  # workflow is running. The review workflow is driven by the
  # `position-review-all` Temporal schedule (every 30 min) — it
  # picks up any open position automatically, so the self-heal
  # no longer needs to start it explicitly. Catches the case
  # where a position exists in the DB but never had the monitor
  # started (e.g. fills that happened before this code shipped,
  # or fills from a deploy where the sync ran but T_CLIENT was
  # briefly unavailable).
  def ensure_position_workflows_running
    Position.open.find_each do |position|
      start_position_workflows(position)
    end
  rescue StandardError => e
    Rails.logger.warn "[alpaca_sync] self-heal failed: #{e.class}: #{e.message[0, 200]}"
  end
end
