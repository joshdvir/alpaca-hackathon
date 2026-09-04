# frozen_string_literal: true

module Api
  class PositionsController < BaseController
    include Paginatable

    def index
      scope = params[:status] == 'closed' ? Position.closed : Position.open
      scope = scope.order(snapshot_at: :desc)
      render json: paginate(scope, serializer: ->(p) { serialize(p) })
    end

    def show
      position = Position.find(params.expect(:id))
      reviews = PositionReview.where(trade_proposal: position.trade_proposals)
                              .order(created_at: :desc)
                              .limit(20)
      render json: {
        position: serialize(position),
        reviews: reviews.map { |r| serialize_review(r) }
      }
    end

    private

    def serialize(p)
      {
        id: p.id,
        symbol: p.symbol,
        qty: p.qty,
        avg_entry_price: p.avg_entry_price,
        market_value: p.market_value,
        unrealized_pl: p.unrealized_pl,
        # `unrealized_plpc` (the "pc" stands for "percent change")
        # is a FRACTION per the Alpaca convention; the front-end
        # multiplies by 100 for display. Field name matches the
        # `PositionsView.vue` key and `AccountController` shape.
        unrealized_plpc: p.unrealized_plpc,
        delta: p.delta,
        gamma: p.gamma,
        theta: p.theta,
        vega: p.vega,
        snapshot_at: p.snapshot_at,
        closed_at: p.closed_at,
        # `created_at` is when the Position row was first written
        # (typically right after the broker fill, by AlpacaSync);
        # `updated_at` moves on every mirror tick that re-snapshots
        # greeks/mark. Both are useful for the operator to see how
        # fresh a position is in the table.
        created_at: p.created_at,
        updated_at: p.updated_at,
        # Mid-Band Movers (and any other strategy-managed position)
        # carries the planned sell time + bucket on the row. Both
        # are nil for default-strategy positions; the front-end
        # shows them only when present.
        origin: p.origin,
        strategy_bucket: p.strategy_bucket,
        planned_sell_at: p.planned_sell_at
      }
    end

    def serialize_review(r)
      {
        id: r.id,
        recommendation: r.recommendation,
        rationale: r.rationale,
        thesis_still_valid: r.thesis_still_valid,
        created_at: r.created_at
      }
    end
  end
end
