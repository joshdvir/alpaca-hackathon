# frozen_string_literal: true

# FindMbmPositionActivity — looks up the open DB Position for a
# given option_symbol + strategy_bucket. Returns the position ID
# (or nil if not found). Used by SellWorkflow to resolve the
# position at sell time, since the position is created by
# AlpacaSync after the buy order fills and may not exist at
# child-spawn time.
#
# The activity also backfills `planned_sell_at` and
# `strategy_bucket` on the position from the order's raw payload
# (SubmitBuyOrdersActivity stashed them there), so the positions
# table gets the strategy metadata regardless of whether the
# mirror had it when the position was first materialized.
#
# `ctx` is the standard {workflow_id, run_id}.

module MidBandMovers
  class FindMbmPositionActivity < ApplicationActivity
    def execute(option_symbol, bucket, ctx = {})
      activity.logger.info "[activity:start] FindMbmPositionActivity symbol=#{option_symbol} bucket=#{bucket}"

      position = ::Position.open.where(symbol: option_symbol).order(snapshot_at: :desc).first
      if position.nil?
        activity.logger.info "[activity:done] FindMbmPositionActivity symbol=#{option_symbol} not_found"
        return nil
      end

      # Backfill metadata if it's missing on the position. The Order
      # row carries the planned_sell_at + strategy_bucket in `raw`
      # (SubmitBuyOrdersActivity stashed them there) — the mirror
      # doesn't move that data onto the Position, so we do it here
      # the first time we look up the position.
      needs_backfill = position.planned_sell_at.nil? || position.strategy_bucket.nil?
      if needs_backfill
        meta = find_order_metadata(option_symbol, bucket)
        if meta
          position.update!(
            planned_sell_at: meta[:planned_sell_at],
            strategy_bucket: meta[:bucket] || bucket,
            origin: 'mid_band_movers'
          )
          activity.logger.info "[activity:done] FindMbmPositionActivity backfilled position=#{position.id} bucket=#{meta[:bucket]} planned_sell_at=#{meta[:planned_sell_at]&.iso8601}"
        else
          # Fall back to setting just the bucket from the workflow arg
          # (the workflow already knows the bucket).
          position.update!(strategy_bucket: bucket, origin: 'mid_band_movers') if position.strategy_bucket.nil?
        end
      end

      position.id
    end

    private

    # Look up the most recent Order for the given option_symbol +
    # bucket and pull the planned_sell_at + bucket out of its
    # `raw_response` JSON (where SubmitBuyOrdersActivity stashed
    # them). If there's no Order yet (buy hasn't been processed),
    # returns nil.
    def find_order_metadata(option_symbol, bucket)
      order = ::Order.where(symbol: option_symbol)
                     .where("raw_response ->> 'mbm_origin' = ?", 'mid_band_movers')
                     .order(created_at: :desc)
                     .first
      return nil if order.nil? || !order.raw_response.is_a?(Hash)

      raw = order.raw_response
      return nil unless raw['mbm_origin'] == 'mid_band_movers'

      {
        planned_sell_at: (raw['mbm_planned_sell_at'] ? Time.iso8601(raw['mbm_planned_sell_at']) : nil),
        bucket: raw['mbm_strategy_bucket'] || bucket
      }
    rescue StandardError => e
      activity.logger.warn "[find_mbm_position] metadata lookup failed: #{e.class}: #{e.message}"
      nil
    end
  end
end
