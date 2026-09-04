# frozen_string_literal: true

require "rails_helper"

# Verifies the persist activity writes a ResearchPlan +
# AnalystReports + (optionally) Bull/Bear cases for every workflow
# run, even on the no_trade / error paths. This is what makes the
# Research screen in the UI non-empty: before this activity, the
# pipeline ran the LLM analysts + debate in memory and only wrote
# rows on the trade path. no_trade → nothing persisted → empty
# screen.
RSpec.describe Trading::PersistResearchActivity do
  let(:info)   { instance_double(Temporalio::Activity::Info, workflow_id: "wf-test-#{SecureRandom.hex(4)}", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Rails.logger, info: info) }

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    TradingConfig.reload!
    # The dev DB has 1900+ TradeProposals. The test only checks
    # research-related tables, so we clean those + the AgentRun
    # rows for our test tickers (using delete_all — no callbacks).
    # We do NOT touch TradeProposal / Order / RiskDecision here
    # because the postgres statement timeout fires on the bulk
    # delete. The test never references them, so leaving the
    # historical rows is harmless.
    tickers = %w[AAPL TSLA NVDA]
    ResearchPlan.where(ticker: tickers).delete_all
    BullCase.where(ticker: tickers).delete_all
    BearCase.where(ticker: tickers).delete_all
    AnalystReport.where(ticker: tickers).delete_all
    AgentRun.where(agent_name: [
      "Analyst::MarketDataAnalyst", "Analyst::NewsAnalyst",
      "Analyst::MacroAnalyst", "Analyst::InsiderAnalyst",
      "Debate::BullResearcher", "Debate::BearResearcher",
      "Debate::ResearchManager"
    ]).where(ticker: tickers).delete_all
  end

  def ctx
    { workflow_id: info.workflow_id, run_id: info.workflow_run_id }
  end

  it "persists a ResearchPlan + 4 AnalystReports on a successful run" do
    briefs = {
      "market_data" => { thesis: "strong setup", signals: ["x"], confidence: 75 },
      "news"        => { thesis: "positive flow", signals: ["x"], confidence: 70 },
      "macro"       => { thesis: "neutral",       signals: ["x"], confidence: 55 },
      "insider"     => { thesis: "no data",       signals: ["x"], confidence: 5 }
    }
    debate = {
      transcript: [
        { speaker: "bull", argument: "long case",   conviction: 80, cited_signals: ["x"] },
        { speaker: "bear", argument: "short case",  conviction: 60, cited_signals: ["x"] }
      ],
      verdict: { verdict: "trade", thesis: "go long", trade_plan: { direction: "bullish" }, confidence: 75 }
    }
    described_class.new.execute("AAPL", briefs, debate, ctx)

    expect(ResearchPlan.where(ticker: "AAPL").count).to eq(1)
    plan = ResearchPlan.where(ticker: "AAPL").first
    expect(plan.recommendation).to eq("bullish")
    expect(plan.confidence).to eq(75)
    expect(plan.synthesis).to eq("go long")

    expect(AnalystReport.where(ticker: "AAPL").count).to eq(4)
    expect(AnalystReport.where(ticker: "AAPL", analyst_name: "market_data").first.confidence).to eq(75)

    expect(BullCase.where(ticker: "AAPL").count).to eq(1)
    expect(BullCase.where(ticker: "AAPL").first.confidence).to eq(80)
    expect(BearCase.where(ticker: "AAPL").count).to eq(1)
    expect(BearCase.where(ticker: "AAPL").first.confidence).to eq(60)
  end

  it "persists even on no_trade verdict (the user's bug — empty Research tab)" do
    briefs = {
      "market_data" => { thesis: "weak", signals: ["x"], confidence: 30 },
      "news"        => { thesis: "no catalyst", signals: ["x"], confidence: 25 },
      "macro"       => { thesis: "neutral", signals: ["x"], confidence: 50 },
      "insider"     => { thesis: "no data",  signals: ["x"], confidence: 5 }
    }
    debate = {
      transcript: [],
      verdict: { verdict: "no_trade", thesis: "low confidence everywhere", confidence: 27, no_trade_reasons: ["conviction < threshold"] }
    }
    described_class.new.execute("TSLA", briefs, debate, ctx)

    expect(ResearchPlan.where(ticker: "TSLA").count).to eq(1)
    plan = ResearchPlan.where(ticker: "TSLA").first
    expect(plan.recommendation).to eq("neutral")
    expect(plan.confidence).to eq(27)
    expect(plan.invalidation_conditions).to eq(["conviction < threshold"])
    expect(AnalystReport.where(ticker: "TSLA").count).to eq(4)
  end

  it "persists even on insufficient_data (LLM/circuit failure)" do
    # All briefs are the default_brief that the agents return on
    # failure. The activity must still write them so the Research
    # tab shows the failure with the error context.
    insufficient = { thesis: "insufficient data (invoke_error)", signals: ["insufficient_data:invoke_error"], confidence: 50, _error: { kind: "invoke_error" } }
    briefs = { "market_data" => insufficient, "news" => insufficient, "macro" => insufficient, "insider" => insufficient }
    debate = {
      transcript: [],
      verdict: { verdict: "no_trade", thesis: "insufficient data", confidence: 0, no_trade_reasons: ["insufficient_data:activity_nil"] }
    }
    described_class.new.execute("NVDA", briefs, debate, ctx)

    expect(ResearchPlan.where(ticker: "NVDA").count).to eq(1)
    expect(AnalystReport.where(ticker: "NVDA").count).to eq(4)
    # All four should have confidence 50 (from the default brief)
    expect(AnalystReport.where(ticker: "NVDA").pluck(:confidence).uniq).to eq([50])
  end

  it "reads thesis from a string-keyed verdict (regression: Temporal JSON boundary)" do
    # Temporal JSON-serializes the activity input, so the debate and
    # verdict hashes arrive with STRING keys, not symbols. The
    # original code read `verdict['synthesis']` but the parser
    # returns `verdict['thesis']` — the miss caused the fallback
    # "(no synthesis — no_trade)" to fire on every plan, even when
    # the LLM had written a thoughtful 200+ word thesis. This test
    # pins the fix by simulating the actual Temporal boundary.
    briefs = {
      "market_data" => { thesis: "x", signals: ["x"], confidence: 50 },
      "news"        => { thesis: "x", signals: ["x"], confidence: 50 },
      "macro"       => { thesis: "x", signals: ["x"], confidence: 50 },
      "insider"     => { thesis: "x", signals: ["x"], confidence: 50 }
    }
    long_thesis = "While the bullish mean-reversion thesis is appealing, " \
                  "the setup is unexecutable due to severe bid/ask dislocation. " \
                  "Distribution signature overrides the lagging-analyst upside case."
    # String keys (post-JSON-deserialization), NOT symbol keys.
    debate = {
      "transcript" => [],
      "verdict" => {
        "verdict" => "no_trade",
        "thesis"  => long_thesis,
        "confidence" => 82,
        "trade_plan" => nil,
        "no_trade_reasons" => ["Severe liquidity"]
      }
    }
    described_class.new.execute("AAPL", briefs, debate, ctx)

    plan = ResearchPlan.where(ticker: "AAPL").first
    expect(plan).not_to be_nil
    expect(plan.synthesis).to eq(long_thesis)
    # The bug: previous behavior was the fallback string.
    expect(plan.synthesis).not_to match(/\(no synthesis/)
  end

  it "reads trade_plan.direction from a string-keyed verdict (regression: same Temporal boundary)" do
    # When the LLM returns verdict='trade' with a trade_plan, the
    # direction must be read from the JSON-deserialized (string-keyed)
    # hash. The original code did `verdict[:trade_plan][:direction]`
    # which silently fell back to 'neutral' because symbol access on
    # a string-keyed hash returns nil.
    briefs = {
      "market_data" => { thesis: "x", signals: ["x"], confidence: 50 },
      "news"        => { thesis: "x", signals: ["x"], confidence: 50 },
      "macro"       => { thesis: "x", signals: ["x"], confidence: 50 },
      "insider"     => { thesis: "x", signals: ["x"], confidence: 50 }
    }
    debate = {
      "transcript" => [],
      "verdict" => {
        "verdict" => "trade",
        "thesis"  => "go long with conviction",
        "confidence" => 70,
        "trade_plan" => { "direction" => "bullish", "thesis" => "long setup" },
        "no_trade_reasons" => []
      }
    }
    described_class.new.execute("AAPL", briefs, debate, ctx)

    plan = ResearchPlan.where(ticker: "AAPL").first
    expect(plan).not_to be_nil
    expect(plan.recommendation).to eq("bullish")
    expect(plan.synthesis).to eq("go long with conviction")
  end

  it "does not fail the activity when the research_manager AgentRun is missing" do
    # Defensive: if the workflow_id doesn't match an existing run
    # (e.g. test isolation), we still want the row to be created.
    briefs = {
      "market_data" => { thesis: "x", signals: ["x"], confidence: 50 },
      "news"        => { thesis: "x", signals: ["x"], confidence: 50 },
      "macro"       => { thesis: "x", signals: ["x"], confidence: 50 },
      "insider"     => { thesis: "x", signals: ["x"], confidence: 50 }
    }
    debate = { transcript: [], verdict: { verdict: "no_trade", thesis: "x", confidence: 0 } }
    # Use a workflow_id that has no matching AgentRun
    bad_ctx = { workflow_id: "wf-never-existed-#{SecureRandom.hex(8)}", run_id: "r1" }
    expect { described_class.new.execute("AAPL", briefs, debate, bad_ctx) }.not_to raise_error
    expect(ResearchPlan.where(ticker: "AAPL").count).to eq(1)
  end
end
