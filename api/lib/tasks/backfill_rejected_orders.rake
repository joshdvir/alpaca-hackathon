# One-shot backfill: mark stuck "new" orders with no broker id as
# `rejected` with the reason we discovered (broker returned an error
# envelope that the old PortfolioManager swallowed). Safe to run
# multiple times — it's idempotent.
namespace :orders do
  desc "Backfill stuck 'new' orders (no broker id) as rejected"
  task backfill_stuck: :environment do
    stuck = Order.where(status: "new", alpaca_order_id: nil)
    count = stuck.count
    if count.zero?
      puts "No stuck orders to backfill."
      next
    end

    stuck.find_each do |o|
      o.update!(
        status: "rejected",
        rejection_reason: "backfill: broker rejected at submit (old code swallowed the error envelope; new PortfolioManager records it). Re-run from a fresh cycle."
      )
    end
    puts "Backfilled #{count} stuck orders as rejected."
  end
end
