# frozen_string_literal: true

# Lightweight OCC option symbol parser.
# Format: ROOT + YYMMDD + C/P + 8-digit strike (strike * 1000).
# Examples:
#   PLTR260911C00190000 → root=PLTR, expiry=2026-09-11, right=call, strike=$19.00
#   SPY260116P00580000  → root=SPY,  expiry=2026-01-16, right=put,  strike=$58.00
#
# We only need expiry for the DTE check in Positions::Monitor. The full
# parser is small enough that parsing on every check is fine (no need to
# denormalize onto the Position model).
module Positions
  module Occ
    SYMBOL_RE = /\A([A-Z]+)(\d{6})([CP])(\d{8})\z/.freeze

    def self.expiry_date(symbol)
      m = SYMBOL_RE.match(symbol.to_s)
      return nil unless m

      yy, mm, dd = m[2][0, 2].to_i, m[2][2, 2].to_i, m[2][4, 2].to_i
      # OCC uses 2-digit years. Anchor to a 100-year window that includes
      # 2025–2099; for the 2000s we treat 00-49 as 2000s and 50-99 as 1900s.
      # In practice we never see pre-2000 OCC symbols.
      year = yy >= 50 ? 1900 + yy : 2000 + yy
      Date.new(year, mm, dd)
    rescue ArgumentError
      # Bad month/day combo (e.g. 260911 for Nov 31).
      nil
    end

    def self.valid?(symbol)
      expiry_date(symbol).present?
    end

    def self.days_to_expiry(symbol, as_of: Date.current)
      exp = expiry_date(symbol)
      return nil if exp.nil?

      (exp - as_of).to_i
    end
  end
end
