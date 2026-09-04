# frozen_string_literal: true

# == Schema Information
#
# Table name: orders
#
#  id                :bigint           not null, primary key
#  filled_at         :datetime
#  filled_avg_price  :decimal(, )
#  filled_qty        :integer          default(0)
#  qty               :integer          not null
#  raw_response      :jsonb
#  rejection_reason  :string
#  side              :string           not null
#  status            :string           default("new"), not null
#  submitted_at      :datetime
#  symbol            :string           not null
#  type              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  alpaca_order_id   :string
#  client_order_id   :string           not null
#  trade_proposal_id :bigint
#
# Indexes
#
#  index_orders_on_alpaca_order_id           (alpaca_order_id) UNIQUE WHERE (alpaca_order_id IS NOT NULL)
#  index_orders_on_client_order_id           (client_order_id) UNIQUE
#  index_orders_on_rejection_reason_present  (rejection_reason) WHERE (rejection_reason IS NOT NULL)
#  index_orders_on_status                    (status)
#  index_orders_on_trade_proposal_id         (trade_proposal_id)
#
# Foreign Keys
#
#  fk_rails_...  (trade_proposal_id => trade_proposals.id)
#
class Order < ApplicationRecord
  include LiveUpdates
  # `type` is the order type (market/limit), NOT a Rails STI discriminator.
  self.inheritance_column = nil

  STATUSES = %w[new filled partial cancelled expired rejected deferred].freeze
  TYPES = %w[market limit].freeze

  belongs_to :trade_proposal, optional: true
  has_many :fills, dependent: :destroy

  validates :client_order_id, :symbol, :side, :qty, :type, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :type, inclusion: { in: TYPES }

  # `open` = orders the broker might still fill. `rejected` (broker
  # rejected at submit) and `deferred` (we chose not to submit, e.g.
  # market closed) are NOT in `open` — they are terminal and we don't
  # want the sync job to keep checking on them.
  scope :open, -> { where(status: %w[new partial]) }
  scope :closed, -> { where(status: %w[filled cancelled expired rejected deferred]) }
  scope :pending_sync, -> { where(status: %w[new partial]) }
  scope :for_symbol, ->(symbol) { where(symbol: symbol) }
end
