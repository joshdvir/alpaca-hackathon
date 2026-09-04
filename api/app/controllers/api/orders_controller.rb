# frozen_string_literal: true

module Api
  class OrdersController < BaseController
    include Paginatable

    def index
      scope = Order.order(submitted_at: :desc, created_at: :desc)
      scope = scope.for_symbol(params[:symbol]) if params[:symbol].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      render json: paginate(scope, serializer: ->(o) { serialize(o) })
    end

    def show
      order = Order.find(params.expect(:id))
      render json: serialize(order).merge(fills: order.fills.map { |f| serialize_fill(f) })
    end

    private

    def serialize(o)
      {
        id: o.id,
        client_order_id: o.client_order_id,
        alpaca_order_id: o.alpaca_order_id,
        symbol: o.symbol,
        side: o.side,
        qty: o.qty,
        filled_qty: o.filled_qty,
        filled_avg_price: o.filled_avg_price,
        type: o.type,
        status: o.status,
        submitted_at: o.submitted_at,
        filled_at: o.filled_at,
        created_at: o.created_at,
        # `updated_at` moves on every status change (new → filled,
        # new → expired, pending → rejected, etc.). The OrdersView
        # table shows it next to `created_at` so the operator can
        # tell at a glance which rows are stale vs recently
        # reconciled by the mirror.
        updated_at: o.updated_at
      }
    end

    def serialize_fill(f)
      {
        id: f.id,
        order_id: f.order_id,
        qty: f.qty,
        price: f.price,
        filled_at: f.filled_at
      }
    end
  end
end
