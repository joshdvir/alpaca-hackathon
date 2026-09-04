# frozen_string_literal: true

# Add rejection_reason + raw_response to orders so the system records WHY
# a broker rejected an order. Without this, broker rejections silently
# leave Order rows at status="new" with no broker id and no audit trail,
# which is the bug behind "I never see any orders get filled".
#
# Also widen the status enum to include "rejected" (broker-level
# rejection) and "deferred" (we chose not to submit — e.g. market
# closed). Both are distinct from the broker-returned states.
class AddOrderRejectionFields < ActiveRecord::Migration[8.0]
  def change
    add_column :orders, :rejection_reason, :string
    add_index  :orders, :rejection_reason, where: "rejection_reason IS NOT NULL", name: "index_orders_on_rejection_reason_present"
  end
end
