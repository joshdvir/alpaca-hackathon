# frozen_string_literal: true

require 'rails_helper'

# Tests for the LLM agent classes' parse() method — the contract that turns
# raw LLM JSON output into the structured hash each agent returns.
# LLM calls are stubbed so these tests don't hit the network.
RSpec.describe 'Agent parse contracts' do # rubocop:disable Metrics/BlockLength
  describe Analyst::Base do # rubocop:disable Metrics/BlockLength
    it 'parses a typical analyst response into thesis/signals/confidence' do
      agent = Analyst::Base.allocate
      result = agent.parse('{"thesis": "bullish", "signals": ["iv 80", "macro tailwind"], "confidence": 75}')
      expect(result[:thesis]).to eq('bullish')
      expect(result[:signals]).to eq(['iv 80', 'macro tailwind'])
      expect(result[:confidence]).to eq(75)
    end

    it 'clamps confidence to 0..100' do
      agent = Analyst::Base.allocate
      high = agent.parse('{"thesis": "x", "signals": [], "confidence": 250}')
      low  = agent.parse('{"thesis": "x", "signals": [], "confidence": -50}')
      expect(high[:confidence]).to eq(100)
      expect(low[:confidence]).to eq(0)
    end

    # The old behavior was to silently default confidence to 50 when
    # the LLM sent a non-numeric value. That made downstream debate
    # agents reason about a fake number, which is worse than failing
    # loudly. Now the parser raises ParseError so the activity is
    # marked error and the operator can fix the prompt.
    it 'raises ParseError on non-numeric confidence (was: defaults to 50)' do
      agent = Analyst::Base.allocate
      expect do
        agent.parse('{"thesis": "x", "signals": [], "confidence": "high"}')
      end.to raise_error(Agent::ParseError, /confidence.*must be numeric/)
    end

    it 'raises ParseError on invalid JSON' do
      agent = Analyst::Base.allocate
      expect { agent.parse('not json') }.to raise_error(Agent::ParseError, /non-JSON/)
    end

    # signals is a REQUIRED key — the agent prompt contract is
    # {thesis, signals, confidence}. Dropping it would let the
    # bull/bear debate get a brief with no concrete signals, which
    # it has to fall back to inventing. Fail loudly instead.
    it 'raises ParseError when signals key is missing' do
      agent = Analyst::Base.allocate
      expect do
        agent.parse('{"thesis": "ok", "confidence": 60}')
      end.to raise_error(Agent::ParseError, /missing required keys.*signals/)
    end

    # LLMs commonly wrap their JSON in prose ("Sure! Here's my
    # analysis: { ... }"). The parser extracts the first balanced
    # {...} block instead of failing the whole activity.
    it 'extracts JSON from a prose wrapper' do
      agent = Analyst::Base.allocate
      prose = 'Sure! Here is the analysis: {"thesis":"IV 78","signals":["iv 78"],"confidence":70}. Hope that helps.'
      result = agent.parse(prose)
      expect(result[:thesis]).to eq('IV 78')
      expect(result[:confidence]).to eq(70)
    end

    it 'extracts JSON from a ```json fenced code block' do
      agent = Analyst::Base.allocate
      fenced = "```json\n{\"thesis\":\"x\",\"signals\":[\"a\"],\"confidence\":50}\n```"
      result = agent.parse(fenced)
      expect(result[:signals]).to eq(['a'])
    end

    # Regression: the LLM almost always wraps its reply in a ```json fence
    # AND uses a nested object for richer fields (e.g. `signals` as
    # `[{...}, {...}]`). The previous non-greedy regex
    # `\{.*?\}` stopped at the first `}` (the close of the inner
    # object) and yielded truncated JSON, which then failed to parse
    # and the pipeline silently fell back to "no_trade" every cycle.
    it 'extracts JSON from a ```json fence with nested objects' do
      agent = Analyst::Base.allocate
      fenced = <<~FENCE
        ```json
        {
          "thesis": "IV 78, momentum positive",
          "signals": [
            { "name": "iv_rank", "value": 78 },
            { "name": "rsi", "value": 62 }
          ],
          "confidence": 75
        }
        ```
      FENCE
      result = agent.parse(fenced)
      expect(result[:thesis]).to eq('IV 78, momentum positive')
      expect(result[:confidence]).to eq(75)
      expect(result[:signals].length).to eq(2)
    end

    it 'rejects prose with no JSON object' do
      agent = Analyst::Base.allocate
      expect do
        agent.parse('I think the setup looks good.')
      end.to raise_error(Agent::ParseError, /no JSON object/)
    end

    it 'rejects signals when it is a String instead of an Array' do
      agent = Analyst::Base.allocate
      expect do
        agent.parse('{"thesis":"x","signals":"iv 78","confidence":50}')
      end.to raise_error(Agent::ParseError, /signals.*must be an Array/)
    end

    it 'rejects confidence when it is non-numeric' do
      agent = Analyst::Base.allocate
      expect do
        agent.parse('{"thesis":"x","signals":[],"confidence":"high"}')
      end.to raise_error(Agent::ParseError, /confidence.*must be numeric/)
    end

    it 'rejects a JSON array at the top level' do
      agent = Analyst::Base.allocate
      expect do
        agent.parse('["thesis", "signals", "confidence"]')
      end.to raise_error(Agent::ParseError, /expected JSON object/)
    end

    it 'tolerates extra fields alongside the required ones' do
      agent = Analyst::Base.allocate
      json = '{"thesis":"x","signals":["s1"],"confidence":50,"rationale":"y","extra":"z"}'
      result = agent.parse(json)
      expect(result[:thesis]).to eq('x')
      expect(result[:signals]).to eq(['s1'])
      expect(result[:confidence]).to eq(50)
    end

    it 'includes the first 500 chars of the bad response in the error' do
      agent = Analyst::Base.allocate
      garbage = ('x' * 1000)
      expect do
        agent.parse(garbage)
      end.to raise_error(Agent::ParseError, /raw_first_500=/)
    end
  end

  describe Debate::Base do
    it 'parses bull/bear argument + cited_signals + conviction' do
      agent = Debate::Base.allocate
      result = agent.parse('{"side": "bull", "argument": "strong tailwind", "cited_signals": ["iv 80"], "conviction": 70}')
      expect(result[:side]).to eq('bull')
      expect(result[:argument]).to eq('strong tailwind')
      expect(result[:cited_signals]).to eq(['iv 80'])
      expect(result[:conviction]).to eq(70)
    end

    it 'clamps conviction to 0..100' do
      agent = Debate::Base.allocate
      result = agent.parse('{"side": "bear", "argument": "x", "cited_signals": [], "conviction": 999}')
      expect(result[:conviction]).to eq(100)
    end
  end

  describe Debate::ResearchManager do
    it "parses a 'trade' verdict with a trade_plan" do
      agent = Debate::ResearchManager.allocate
      json = <<~JSON
        {
          "verdict": "trade",
          "thesis": "ok",
          "trade_plan": { "strategy": "vertical", "direction": "bullish" },
          "confidence": 80,
          "no_trade_reasons": []
        }
      JSON
      result = agent.parse(json)
      expect(result[:verdict]).to eq('trade')
      expect(result[:trade_plan]['strategy']).to eq('vertical')
      expect(result[:confidence]).to eq(80)
      expect(result[:no_trade_reasons]).to eq([])
    end

    it "parses a 'no_trade' verdict with reasons" do
      agent = Debate::ResearchManager.allocate
      json = '{"verdict": "no_trade", "thesis": "low confidence", "trade_plan": null, "confidence": 20, "no_trade_reasons": ["low iv", "earnings risk"]}'
      result = agent.parse(json)
      expect(result[:verdict]).to eq('no_trade')
      expect(result[:no_trade_reasons]).to eq(['low iv', 'earnings risk'])
    end

    # Regression: production LLM (MiniMax-M3) almost always wraps its reply
    # in a ```json fence AND returns a `trade_plan` nested object. The
    # previous `JSON.parse(content)` raised
    # `unexpected character: '```json' at line 1 column 1` and the
    # research manager fell back to no_trade every cycle, even when
    # the actual analysis was a confident trade. This is the bug
    # that was blocking the pipeline end-to-end.
    it 'parses a ```json fenced trade verdict with a nested trade_plan' do
      agent = Debate::ResearchManager.allocate
      fenced = <<~FENCE
        ```json
        {
          "verdict": "trade",
          "thesis": "bullish momentum + insider buying",
          "trade_plan": {
            "strategy": "vertical",
            "direction": "bullish",
            "rationale": "long the ATM call, short the 5-point OTM call"
          },
          "confidence": 72,
          "no_trade_reasons": []
        }
        ```
      FENCE
      result = agent.parse(fenced)
      expect(result[:verdict]).to eq('trade')
      expect(result[:trade_plan]['strategy']).to eq('vertical')
      expect(result[:confidence]).to eq(72)
    end
  end

  describe Trader do
    it 'parses a single-leg option proposal (legacy shape, wrapped into a one-leg array)' do
      agent = Trader.allocate
      json = <<~JSON
        {
          "proposal": {
            "symbol": "SPY260116C00580000",
            "side": "buy_to_open",
            "qty": 1,
            "limit_price": 1.25,
            "tif": "day",
            "rationale": "play the breakout"
          }
        }
      JSON
      result = agent.parse(json)
      # Return shape MUST match Trader.default_brief
      # (`{proposal: nil, _insufficient: true, ...}`) so that
      # RunExecutionPhaseActivity's `result[:proposal].nil?` check
      # correctly distinguishes success from failure.
      # The parser normalizes both single-leg and multi-leg into
      # `{proposal: {legs: [...]}}` so the downstream pipeline only
      # ever sees the legs-array shape.
      expect(result[:proposal]).not_to be_nil
      expect(result[:proposal][:legs].size).to eq(1)
      leg = result[:proposal][:legs].first
      expect(leg['symbol']).to eq('SPY260116C00580000')
      expect(leg['side']).to eq('buy_to_open')
      expect(leg['qty']).to eq(1)
      expect(leg['limit_price']).to eq(1.25)
      expect(result[:proposal][:tif]).to eq('day')
      expect(result[:proposal][:rationale]).to eq('play the breakout')
    end

    it 'parses a ```json fenced single-leg proposal' do
      agent = Trader.allocate
      fenced = <<~FENCE
        ```json
        {"proposal": {"symbol": "EOG260925P00142500", "side": "buy_to_open", "qty": 1, "limit_price": 4.0, "rationale": "long the put"}}
        ```
      FENCE
      result = agent.parse(fenced)
      leg = result[:proposal][:legs].first
      expect(leg['symbol']).to eq('EOG260925P00142500')
      expect(leg['side']).to eq('buy_to_open')
    end

    it 'parses a multi-leg (spread) proposal with a net limit_price' do
      agent = Trader.allocate
      json = <<~JSON
        {
          "proposal": {
            "legs": [
              { "symbol": "SPY260116C00580000", "side": "buy_to_open",  "qty": 1, "limit_price": 5.20 },
              { "symbol": "SPY260116C00600000", "side": "sell_to_open", "qty": 1, "limit_price": 3.75 }
            ],
            "limit_price": -1.45,
            "tif": "day",
            "rationale": "Bull call vertical"
          }
        }
      JSON
      result = agent.parse(json)
      expect(result[:proposal][:legs].size).to eq(2)
      first, second = result[:proposal][:legs]
      expect(first['side']).to eq('buy_to_open')
      expect(second['side']).to eq('sell_to_open')
      # Net limit price is attached to every leg so PortfolioManager
      # can read it from any one.
      expect(first['net_limit_price']).to eq(BigDecimal('-1.45'))
      expect(second['net_limit_price']).to eq(BigDecimal('-1.45'))
    end

    it 'parses a ```json fenced multi-leg proposal' do
      agent = Trader.allocate
      fenced = <<~FENCE
        ```json
        {
          "proposal": {
            "legs": [
              { "symbol": "PLTR260911C00190000", "side": "buy_to_open",  "qty": 1, "limit_price": 3.50 },
              { "symbol": "PLTR260911C00200000", "side": "sell_to_open", "qty": 1, "limit_price": 2.00 }
            ],
            "limit_price": 1.50,
            "rationale": "PLTR bull call vertical"
          }
        }
        ```
      FENCE
      result = agent.parse(fenced)
      expect(result[:proposal][:legs].size).to eq(2)
      expect(result[:proposal][:legs].first['symbol']).to eq('PLTR260911C00190000')
      expect(result[:proposal][:legs].last['side']).to eq('sell_to_open')
    end

    it 'computes net_limit_price from per-leg prices when proposal limit_price is missing (LLM-typical shape)' do
      # When the LLM emits per-leg prices but no proposal-level net
      # (the prompt's multi-leg example shows only per-leg prices),
      # the parser must compute net = Σ(leg_price × sign(side)) so
      # the broker has a limit to send. Without this the order
      # reaches Alpaca with limit_price=nil and gets 42210000.
      agent = Trader.allocate
      json = <<~JSON
        {
          "proposal": {
            "legs": [
              { "symbol": "BAC260918C00062000", "side": "buy_to_open",  "qty": 15, "limit_price": 2.0 },
              { "symbol": "BAC260918C00064000", "side": "sell_to_open", "qty": 15, "limit_price": 0.8 }
            ],
            "tif": "day",
            "rationale": "BAC bull call vertical"
          }
        }
      JSON
      result = agent.parse(json)
      first, second = result[:proposal][:legs]
      # net = 2.0 - 0.8 = 1.2 (debit)
      expect(first['net_limit_price']).to eq(BigDecimal('1.2'))
      expect(second['net_limit_price']).to eq(BigDecimal('1.2'))
    end

    it 'computes a negative net (credit) for an iron condor' do
      agent = Trader.allocate
      json = <<~JSON
        {
          "proposal": {
            "legs": [
              { "symbol": "NVDA260904P00210000", "side": "buy_to_open",  "qty": 15, "limit_price": 0.55 },
              { "symbol": "NVDA260904P00215000", "side": "sell_to_open", "qty": 15, "limit_price": 1.30 },
              { "symbol": "NVDA260904C00222000", "side": "sell_to_open", "qty": 15, "limit_price": 1.40 },
              { "symbol": "NVDA260904C00225000", "side": "buy_to_open",  "qty": 15, "limit_price": 0.20 }
            ],
            "tif": "day",
            "rationale": "NVDA iron condor"
          }
        }
      JSON
      result = agent.parse(json)
      legs = result[:proposal][:legs]
      # net = 0.55 - 1.30 - 1.40 + 0.20 = -1.95 (credit)
      legs.each { |l| expect(l['net_limit_price']).to eq(BigDecimal('-1.95')) }
    end

    it 'raises ParseError when a multi-leg leg has non-numeric qty' do
      agent = Trader.allocate
      bad = <<~JSON
        {
          "proposal": {
            "legs": [
              { "symbol": "X", "side": "buy_to_open", "qty": "high", "limit_price": 1.0 }
            ]
          }
        }
      JSON
      expect do
        agent.parse(bad)
      end.to raise_error(Agent::ParseError, /malformed|missing|Integer/i)
    end

    it 'raises ParseError when the proposal has neither legs nor symbol+side' do
      agent = Trader.allocate
      expect do
        agent.parse('{"proposal": {"rationale": "forgot to include the order"}}')
      end.to raise_error(Agent::ParseError, /legs.*multi-leg|symbol.*side/i)
    end

    it 'raises ParseError on non-JSON input' do
      agent = Trader.allocate
      expect { agent.parse('nope') }.to raise_error(Agent::ParseError, /non-JSON/)
    end
  end

  describe Positions::Base do
    it 'accepts each of the five valid actions' do
      Positions::Base::ACTIONS.each do |action|
        agent = Positions::Base.allocate
        result = agent.parse(%({"action": "#{action}", "reason": "because"}))
        expect(result[:action]).to eq(action)
      end
    end

    it 'rejects unknown actions' do
      agent = Positions::Base.allocate
      expect do
        agent.parse('{"action": "destroy", "reason": "because"}')
      end.to raise_error(Agent::ParseError, /invalid action/)
    end

    it 'defaults :details to {} when absent' do
      agent = Positions::Base.allocate
      result = agent.parse('{"action": "hold", "reason": "stable"}')
      expect(result[:details]).to eq({})
    end

    # Regression: PositionReviewAgent and AdjustmentAgent both inherit
    # Positions::Base#parse. Production log showed
    # `PositionReviewAgent returned non-JSON: unexpected character: '```json'`
    # because the parser was calling `JSON.parse(content)` directly
    # instead of the inherited `extract_json` helper. Every 30-min review
    # cycle then fell through to `action: nil`, the workflow treated it
    # as hold, and the position never got an actual review.
    it 'parses a ```json fenced response' do
      agent = Positions::Base.allocate
      fenced = "```json\n{\"action\": \"hold\", \"reason\": \"stable\", \"details\": {}}\n```"
      result = agent.parse(fenced)
      expect(result[:action]).to eq('hold')
      expect(result[:reason]).to eq('stable')
    end

    it 'parses a ```json fenced non-hold response with details' do
      agent = Positions::Base.allocate
      fenced = <<~FENCE
        ```json
        {
          "action": "close",
          "reason": "stop loss hit",
          "details": { "side": "sell_to_close", "qty": 1 }
        }
        ```
      FENCE
      result = agent.parse(fenced)
      expect(result[:action]).to eq('close')
      expect(result[:details]['side']).to eq('sell_to_close')
    end

    it 'raises ParseError on truly malformed content (no JSON at all)' do
      agent = Positions::Base.allocate
      expect { agent.parse('no json here') }.to raise_error(Agent::ParseError, /non-JSON|no JSON/)
    end
  end

  describe Analyst::Base, 'user_payload' do
    it 'includes the ticker, watchlist tags, and market context' do
      we = WatchlistEntry.create!(
        ticker: 'AAPL', effective_from: Date.current, source: 'manual', cycle_minutes: 30,
        tags: ['high_iv']
      )
      agent = Analyst::Base.new
      payload = agent.user_payload('AAPL', we, { foo: 'bar' })
      expect(payload[:ticker]).to eq('AAPL')
      expect(payload[:watchlist_tags]).to eq(['high_iv'])
      expect(payload[:cycle_minutes]).to eq(30)
      expect(payload[:market_context]).to eq({ foo: 'bar' })
    end
  end
end
