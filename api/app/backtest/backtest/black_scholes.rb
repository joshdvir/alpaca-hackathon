# frozen_string_literal: true

# Black-Scholes pricer for backtest option synthesis. Not used in live
# trading — only inside Backtest::HistoricalDataProvider.
#
# API:
#   BlackScholes.price(spot:, strike:, t:, r:, sigma:, right: "C"|"P") -> Float
#   BlackScholes.greeks(spot:, strike:, t:, r:, sigma:, right:) -> {delta:, gamma:, theta:, vega:}
#
# All inputs are decimals/floats; the pricer returns Float.

module Backtest
  module BlackScholes
    module_function

    def price(spot:, strike:, t:, r:, sigma:, right:)
      d1 = (Math.log(spot.to_f / strike) + ((r.to_f + (0.5 * (sigma.to_f**2))) * t.to_f)) / (sigma.to_f * Math.sqrt(t.to_f))
      d2 = d1 - (sigma.to_f * Math.sqrt(t.to_f))
      if right.to_s.upcase == 'C'
        (spot.to_f * norm_cdf(d1)) - (strike.to_f * Math.exp(-r.to_f * t.to_f) * norm_cdf(d2))
      else
        (strike.to_f * Math.exp(-r.to_f * t.to_f) * norm_cdf(-d2)) - (spot.to_f * norm_cdf(-d1))
      end
    end

    def greeks(spot:, strike:, t:, r:, sigma:, right:)
      d1 = (Math.log(spot.to_f / strike) + ((r.to_f + (0.5 * (sigma.to_f**2))) * t.to_f)) / (sigma.to_f * Math.sqrt(t.to_f))
      d2 = d1 - (sigma.to_f * Math.sqrt(t.to_f))
      pdf_d1 = norm_pdf(d1)
      is_call = right.to_s.upcase == 'C'
      {
        delta: is_call ? norm_cdf(d1) : norm_cdf(d1) - 1.0,
        gamma: pdf_d1 / (spot.to_f * sigma.to_f * Math.sqrt(t.to_f)),
        theta: theta(spot: spot, strike: strike, t: t, r: r, sigma: sigma, d1: d1, d2: d2, is_call: is_call),
        vega: spot.to_f * pdf_d1 * Math.sqrt(t.to_f) / 100.0
      }
    end

    # Abramowitz & Stegun approximation of the standard normal CDF.
    def norm_cdf(x)
      0.5 * (1.0 + Math.erf(x / Math.sqrt(2.0)))
    end

    def norm_pdf(x)
      Math.exp(-0.5 * x * x) / Math.sqrt(2.0 * Math::PI)
    end

    def theta(spot:, strike:, t:, r:, sigma:, d1:, d2:, is_call:)
      common = -(spot.to_f * norm_pdf(d1) * sigma.to_f) / (2.0 * Math.sqrt(t.to_f))
      if is_call
        common - (r.to_f * strike.to_f * Math.exp(-r.to_f * t.to_f) * norm_cdf(d2))
      else
        common + (r.to_f * strike.to_f * Math.exp(-r.to_f * t.to_f) * norm_cdf(-d2))
      end
    end
  end
end
