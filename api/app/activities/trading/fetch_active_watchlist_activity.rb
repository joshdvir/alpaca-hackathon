# frozen_string_literal: true

# FetchActiveWatchlistActivity — returns the current watchlist for the
# SchedulerWorkflow to fan out. Pure DB read, no LLM. Result is a list of
# compact hashes (id, ticker, cycle_minutes, tags) so the workflow can
# persist search attributes and pass them down to child workflows.

module Trading
  class FetchActiveWatchlistActivity < ApplicationActivity
    def execute
      WatchlistEntry.active.order(:cycle_minutes, :ticker).map do |w|
        {
          id: w.id,
          ticker: w.ticker,
          cycle_minutes: w.cycle_minutes,
          source: w.source,
          tags: w.tags,
          effective_from: w.effective_from,
          effective_until: w.effective_until
        }
      end
    end
  end
end
