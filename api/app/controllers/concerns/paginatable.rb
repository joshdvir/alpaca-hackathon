# frozen_string_literal: true

# Paginatable — shared concern for list endpoints that need cursor
# pagination. Each list endpoint reads `?page=N&per_page=M` from the
# query string, clamps to safe defaults, and returns
# `{items: [...], total: N, page: N, per_page: M, total_pages: N}`
# so the front-end can render a page indicator.
#
# Why a concern instead of a gem: we want the same defaults everywhere
# (page 1, 50 per page, 200 max) without per-controller tweaks, and
# we want a stable JSON envelope so the front-end Pagination component
# can be endpoint-agnostic.
#
# Usage:
#   class OrdersController < BaseController
#     include Paginatable
#     def index
#       scope = Order.order(submitted_at: :desc)
#       scope = scope.for_symbol(params[:symbol]) if params[:symbol].present?
#       render json: paginate(scope, serializer: ->(o) { serialize(o) })
#     end
#   end
#
# `serializer` is a lambda that turns one AR record into a hash. If
# omitted the records are rendered as their `as_json` (works for
# simple models, less useful for ones with associations).
#
# The `total` count comes from `.count` on the SCOPE BEFORE limit/offset
# is applied, so the page indicator can show "page 2 of 17".

module Paginatable
  extend ActiveSupport::Concern

  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE     = 200

  def paginate(scope, serializer: nil)
    page     = [params[:page].to_i, 1].max
    per_page = (params[:per_page] || DEFAULT_PER_PAGE).to_i
    per_page = DEFAULT_PER_PAGE if per_page <= 0
    per_page = MAX_PER_PAGE if per_page > MAX_PER_PAGE

    total = scope.count
    records = scope.limit(per_page).offset((page - 1) * per_page).to_a

    {
      items: records.map { |r| serializer ? serializer.call(r) : r.as_json },
      total: total,
      page: page,
      per_page: per_page,
      total_pages: (total.to_f / per_page).ceil
    }
  end
end
