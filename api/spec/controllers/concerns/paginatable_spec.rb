# frozen_string_literal: true

require 'rails_helper'

# Tests for the Paginatable concern. The concern is mixed into the
# list controllers (orders, positions, etc.); we use a tiny throwaway
# controller here so we can exercise the helper without dragging in
# model fixtures.

RSpec.describe Paginatable, type: :controller do
  # Fake controller that includes the concern and exposes paginate
  # via a public action.
  controller(ActionController::API) do
    include Paginatable

    def index
      items = (1..25).to_a
      render json: paginate(FakeScope.new(items), serializer: ->(i) { { n: i } })
    end
  end

  # Mimics just enough of an ActiveRecord::Relation: responds to
  # .count, .limit(n), .offset(o), .to_a. AR's `scope.limit(n).offset(o)`
  # returns a relation that, when enumerated, applies BOTH
  # (effectively `scope.offset(o).limit(n)`). Our fake stores the
  # offset + limit and applies them together in `to_a` so the same
  # semantics hold.
  class FakeScope
    def initialize(items, offset: 0, limit: nil)
      @items = items.dup
      @offset = offset
      @limit = limit
    end

    def count
      @items.length
    end

    def limit(n)
      self.class.new(@items, offset: @offset, limit: n)
    end

    def offset(o)
      self.class.new(@items, offset: o, limit: @limit)
    end

    def to_a
      sliced = @items.drop(@offset)
      @limit ? sliced.first(@limit) : sliced
    end
  end

  it 'returns the first page with default per_page' do
    get :index
    body = JSON.parse(response.body)
    expect(body['items'].length).to eq(25)
    expect(body['items'].first).to eq({ 'n' => 1 })
    expect(body['page']).to eq(1)
    expect(body['per_page']).to eq(50)
    expect(body['total']).to eq(25)
    expect(body['total_pages']).to eq(1)
  end

  it 'honors the page query param' do
    get :index, params: { page: 2, per_page: 10 }
    body = JSON.parse(response.body)
    expect(body['items'].length).to eq(10)
    expect(body['items'].first).to eq({ 'n' => 11 })
    expect(body['page']).to eq(2)
    expect(body['per_page']).to eq(10)
    expect(body['total']).to eq(25)
    expect(body['total_pages']).to eq(3)
  end

  it 'clamps per_page to the configured max' do
    get :index, params: { per_page: 10_000 }
    body = JSON.parse(response.body)
    expect(body['per_page']).to eq(Paginatable::MAX_PER_PAGE)
  end

  it 'falls back to defaults for non-numeric per_page' do
    get :index, params: { per_page: 'abc' }
    body = JSON.parse(response.body)
    expect(body['per_page']).to eq(Paginatable::DEFAULT_PER_PAGE)
  end

  it 'clamps page to 1 when invalid' do
    get :index, params: { page: 0 }
    body = JSON.parse(response.body)
    expect(body['page']).to eq(1)
  end

  it 'returns empty items + correct total when the page is past the end' do
    get :index, params: { page: 99, per_page: 50 }
    body = JSON.parse(response.body)
    expect(body['items']).to eq([])
    expect(body['total']).to eq(25)
  end
end
