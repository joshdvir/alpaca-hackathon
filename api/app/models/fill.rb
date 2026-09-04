# frozen_string_literal: true

# == Schema Information
#
# Table name: fills
#
#  id             :bigint           not null, primary key
#  filled_at      :datetime         not null
#  price          :decimal(, )      not null
#  qty            :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  alpaca_fill_id :string
#  order_id       :bigint           not null
#
# Indexes
#
#  index_fills_on_alpaca_fill_id  (alpaca_fill_id) UNIQUE WHERE (alpaca_fill_id IS NOT NULL)
#  index_fills_on_order_id        (order_id)
#
# Foreign Keys
#
#  fk_rails_...  (order_id => orders.id)
#
class Fill < ApplicationRecord
  belongs_to :order
end
