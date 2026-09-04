# frozen_string_literal: true

module TickerSelector
  class FetchUniverseActivity < ApplicationActivity
    def execute
      activity.logger.info "[ticker_selector] FetchUniverse starting"
      activity.heartbeat("starting get_all_assets")
      symbols = UniverseProvider.fetch
      activity.logger.info "[ticker_selector] FetchUniverse done: #{symbols.size} symbols"
      symbols
    end
  end
end
