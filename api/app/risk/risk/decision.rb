# frozen_string_literal: true

# Immutable value object representing a risk check outcome.
# Returned by RiskManager.check — never persisted directly. The
# RiskDecision AR model (in app/models/risk_decision.rb) holds the
# persisted form with a trade_proposal FK.

module Risk
  Decision = Data.define(:approved, :reasons, :limit_snapshot) do
    def approved? = approved
    def rejected? = !approved
  end
end
