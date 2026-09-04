# frozen_string_literal: true

require "rails_helper"

# Verifies TickerSelector::FilterEngine uses the right ruby_llm-mcp
# 1.0+ API for safe_call (client.tool(name) + tool.call(**kwargs)).
# rubocop:disable Metrics/BlockLength
RSpec.describe TickerSelector::FilterEngine do
  describe ".safe_call" do
    let(:fake_client) { instance_double(RubyLLM::MCP::Client) }
    let(:fake_tool) { instance_double(RubyLLM::MCP::Tool) }
    # Use a plain hash so the cache layer (Solid Cache / Marshal) can
    # serialize the value. `instance_double(RubyLLM::MCP::Content)` is
    # not marshalable.
    let(:fake_content) { { 'foo' => 1 } }

    before do
      stub_const('ALPACA_MCP_READONLY', fake_client)
      Rails.cache.clear # ensure the cache sees a miss for each test
    end

    it "looks up the tool by name and calls it with the args hash" do
      allow(fake_client).to receive(:tool).with('get_stock_bars').and_return(fake_tool)
      expected_args = { symbol: 'AAPL', timeframe: '1Day' }
      expect(fake_tool).to receive(:call).with(expected_args).and_return(fake_content)

      result = described_class.safe_call('get_stock_bars', expected_args)
      expect(result).to be(fake_content)
    end

    it "returns nil when the tool is not found on the server" do
      allow(fake_client).to receive(:tool).with('missing_tool').and_return(nil)
      expect(described_class.safe_call('missing_tool', { symbol: 'AAPL' })).to be_nil
    end

    it "rescues and returns nil on tool errors" do
      allow(fake_client).to receive(:tool).with('get_stock_bars').and_return(fake_tool)
      allow(fake_tool).to receive(:call).and_raise(StandardError, 'rate limited')

      result = described_class.safe_call('get_stock_bars', { symbol: 'AAPL' })
      expect(result).to be_nil
    end

    it "retries on 429 raised exceptions with exponential backoff" do
      allow(fake_client).to receive(:tool).with('get_stock_bars').and_return(fake_tool)
      call_count = 0
      allow(fake_tool).to receive(:call) do
        call_count += 1
        call_count < 2 ? raise(StandardError, 'HTTP error 429: Too Many Requests') : fake_content
      end
      # Stub sleep so the test doesn't actually wait
      allow(described_class).to receive(:sleep)

      result = described_class.safe_call('get_stock_bars', { symbol: 'AAPL' })
      expect(result).to be(fake_content)
      expect(call_count).to eq(2)
    end

    it "retries on 429 in the response body and eventually gives up" do
      allow(fake_client).to receive(:tool).with('get_news').and_return(fake_tool)
      # Use a Struct to mimic MCP::Content (responds to :text) without
      # being a singleton that Marshal can't dump.
      rate_limited_content = Struct.new(:text).new(
        '{"error":"Tool execution error: HTTP error 429: Too Many Requests"}'
      )
      allow(fake_tool).to receive(:call).and_return(rate_limited_content)
      allow(described_class).to receive(:sleep)

      result = described_class.safe_call('get_news', { symbols: 'AAPL' })
      # After MAX_429_RETRIES (3) attempts, gives up and returns nil
      expect(result).to be_nil
    end

    it "returns the result immediately on success (no retry)" do
      allow(fake_client).to receive(:tool).with('get_stock_bars').and_return(fake_tool)
      expect(fake_tool).to receive(:call).once.and_return(fake_content)
      allow(described_class).to receive(:sleep) # ensure no sleeps

      result = described_class.safe_call('get_stock_bars', { symbol: 'AAPL' })
      expect(result).to be(fake_content)
    end

    it "tolerates a nil args hash" do
      allow(fake_client).to receive(:tool).with('get_news').and_return(fake_tool)
      allow(fake_tool).to receive(:call).and_return(fake_content)

      result = described_class.safe_call('get_news', nil)
      expect(result).to be(fake_content)
    end

    it "caches the response via Rails.cache and skips the tool call on the second invocation" do
      allow(fake_client).to receive(:tool).with('get_stock_bars').and_return(fake_tool)
      cached_payload = { 'bars' => { 'SPY' => [{ 'c' => 1.0 }] } }
      expect(fake_tool).to receive(:call).once.and_return(cached_payload)

      first  = described_class.safe_call('get_stock_bars', { symbol: 'AAPL', timeframe: '1Day' })
      second = described_class.safe_call('get_stock_bars', { symbol: 'AAPL', timeframe: '1Day' })
      expect(first).to eq(cached_payload)
      expect(second).to eq(cached_payload) # cache hit, no second MCP call
    end

    it "treats args with the same keys in different orders as a cache hit" do
      allow(fake_client).to receive(:tool).with('get_stock_bars').and_return(fake_tool)
      cached_payload = { 'bars' => { 'SPY' => [{ 'c' => 1.0 }] } }
      expect(fake_tool).to receive(:call).once.and_return(cached_payload)

      described_class.safe_call('get_stock_bars', { symbol: 'AAPL', timeframe: '1Day' })
      described_class.safe_call('get_stock_bars', { timeframe: '1Day', symbol: 'AAPL' })
      # Only one MCP call — the order-insensitive cache key matched
    end
  end

  describe ".fetch_bars_batch" do
    let(:bars_payload) do
      { 'bars' => {
        'AAPL' => [{ 'c' => 100, 't' => '2026-08-25' }, { 'c' => 105, 't' => '2026-08-26' }],
        'MSFT' => [{ 'c' => 200, 't' => '2026-08-25' }, { 'c' => 210, 't' => '2026-08-26' }]
      } }
    end
    # Stub safe_call directly to bypass the cache layer (which can't
    # Marshal the Struct content). This is what we're really testing
    # anyway: that fetch_bars_batch makes one MCP call.
    before do
      allow(described_class).to receive(:safe_call) do |tool_name, args|
        case tool_name
        when 'get_stock_bars'
          Struct.new(:text).new(bars_payload.to_json)
        end
      end
    end

    it "makes ONE MCP call for many tickers (not one per ticker)" do
      expect(described_class).to receive(:safe_call).once do |tool_name, args|
        expect(tool_name).to eq('get_stock_bars')
        expect(args[:symbols]).to eq('AAPL,MSFT,NVDA')
        expect(args[:timeframe]).to eq('1Day')
        Struct.new(:text).new(bars_payload.to_json)
      end

      result = described_class.fetch_bars_batch(%w[AAPL MSFT NVDA])
      expect(result.keys).to match_array(%w[AAPL MSFT NVDA])
      expect(result['AAPL'].size).to eq(2)
      expect(result['MSFT'].size).to eq(2)
      expect(result['NVDA']).to eq([]) # not in response → empty array
    end

    it "returns {} for empty input" do
      expect(described_class).not_to receive(:safe_call)
      expect(described_class.fetch_bars_batch([])).to eq({})
    end
  end

  describe ".fetch_news_batch" do
    let(:news_payload) do
      [
        { 'headline' => 'AAPL news', 'symbols' => ['AAPL'], 'created_at' => '2026-08-28T10:00:00Z' },
        { 'headline' => 'MSFT news', 'symbols' => ['MSFT'], 'created_at' => '2026-08-27T10:00:00Z' },
        { 'headline' => 'AAPL+MSFT news', 'symbols' => ['AAPL', 'MSFT'], 'created_at' => '2026-08-26T10:00:00Z' }
      ]
    end

    before do
      allow(described_class).to receive(:safe_call) do |tool_name, args|
        Struct.new(:text).new(news_payload.to_json)
      end
    end

    it "makes ONE MCP call for many tickers" do
      expect(described_class).to receive(:safe_call).once do |tool_name, args|
        expect(tool_name).to eq('get_news')
        expect(args[:symbols]).to eq('AAPL,MSFT,NVDA')
        expect(args[:start]).to be_a(String)
        Struct.new(:text).new(news_payload.to_json)
      end

      result = described_class.fetch_news_batch(%w[AAPL MSFT NVDA])
      expect(result.size).to eq(3)
    end

    it "returns [] for empty input" do
      expect(described_class).not_to receive(:safe_call)
      expect(described_class.fetch_news_batch([])).to eq([])
    end
  end

  describe ".fetch_chains_parallel" do
    it "returns {} for empty input without spawning threads" do
      expect(described_class).not_to receive(:fetch_option_chain)
      expect(described_class.fetch_chains_parallel([])).to eq({})
    end

    it "fetches one chain per ticker and returns a {ticker => chain} hash" do
      tickers = %w[AAPL MSFT NVDA GOOG AMZN]
      allow(described_class).to receive(:fetch_option_chain) do |ticker|
        { "#{ticker}260919C00150000" => { greeks: { iv: 0.30 } } }
      end

      result = described_class.fetch_chains_parallel(tickers)

      expect(result.keys.sort).to eq(tickers.sort)
      result.each do |ticker, chain|
        expect(chain.keys.first).to start_with(ticker)
      end
      expect(described_class).to have_received(:fetch_option_chain).exactly(tickers.size).times
    end

    it "completes for a 50-ticker chunk (CHAIN_PARALLELISM bounds the threads)" do
      tickers = (1..50).map { |i| "T#{i.to_s.rjust(2, '0')}" }
      allow(described_class).to receive(:fetch_option_chain).and_return({})

      result = described_class.fetch_chains_parallel(tickers)
      expect(result.size).to eq(50)
    end
  end

  describe ".news_items_for" do
    let(:news) do
      [
        { 'headline' => 'AAPL news', 'symbols' => ['AAPL'] },
        { 'headline' => 'MSFT news', 'symbols' => ['MSFT'] },
        { 'headline' => 'cross-ticker', 'symbols' => ['AAPL', 'MSFT'] }
      ]
    end

    it "filters to only items whose symbols array includes the ticker" do
      aapl = described_class.news_items_for(news, 'AAPL')
      expect(aapl.map { |n| n['headline'] }).to eq(['AAPL news', 'cross-ticker'])

      msft = described_class.news_items_for(news, 'MSFT')
      expect(msft.map { |n| n['headline'] }).to eq(['MSFT news', 'cross-ticker'])

      expect(described_class.news_items_for(news, 'NVDA')).to eq([])
    end

    it "tolerates items with missing symbols key" do
      bad = [{ 'headline' => 'no symbols' }]
      expect(described_class.news_items_for(bad, 'AAPL')).to eq([])
    end
  end

  describe ".parse" do
    it "returns nil for nil content" do
      expect(described_class.parse(nil)).to be_nil
    end

    it "returns nil for content with no text" do
      expect(described_class.parse(double(text: nil))).to be_nil
    end

    it "parses JSON from content.text (bare array)" do
      content = double(text: '[{"c":1.0}]')
      expect(described_class.parse(content)).to eq([{ 'c' => 1.0 }])
    end

    it "parses JSON from a wrapped MCP response" do
      content = double(text: '{"_alpaca_mcp_security":{},"data":{"result":[{"c":1.0}]}}')
      # Without a tool_name, Mcp::Response falls back to find_array, which
      # walks into the structure and returns the first Array it sees.
      expect(described_class.parse(content)).to eq([{ 'c' => 1.0 }])
    end

    it "returns nil on JSON parse errors" do
      content = double(text: 'not json {{')
      expect(described_class.parse(content)).to be_nil
    end
  end

  describe ".extract_option_chain" do
    it "unwraps a get_option_chain MCP response" do
      env = {
        '_alpaca_mcp_security' => {},
        'data' => {
          'snapshots' => {
            'SPY260831C00420000' => {
              'greeks' => { 'iv' => 0.30, 'delta' => 0.5 },
              'dailyBar' => { 'c' => 345.0 }
            }
          }
        }
      }
      content = instance_double(RubyLLM::MCP::Content, text: env.to_json)
      result = described_class.extract_option_chain(content)
      expect(result.keys).to eq(['SPY260831C00420000'])
      expect(result['SPY260831C00420000']['greeks']['iv']).to eq(0.30)
    end

    it "returns {} when the content is nil" do
      expect(described_class.extract_option_chain(nil)).to eq({})
    end
  end

  describe ".iv_rank" do
    it "extracts IV (as a 0-100 number) from a get_option_chain snapshot" do
      chain = {
        'SPY260831C00420000' => {
          'greeks' => { 'iv' => 0.30, 'delta' => 0.5 }
        }
      }
      expect(described_class.iv_rank(chain)).to eq(30.0)
    end

    it "falls back to impliedVolatility if greeks.iv is missing" do
      chain = { 'SPY260831C00420000' => { 'impliedVolatility' => 0.42 } }
      expect(described_class.iv_rank(chain)).to eq(42.0)
    end

    it "returns nil for an empty chain" do
      expect(described_class.iv_rank({})).to be_nil
    end

    it "returns nil when no snapshot has an IV" do
      chain = { 'SPY260831C00420000' => { 'greeks' => { 'delta' => 0.5 } } }
      expect(described_class.iv_rank(chain)).to be_nil
    end

    it "returns nil for nil input" do
      expect(described_class.iv_rank(nil)).to be_nil
    end
  end

  describe ".avg_open_interest" do
    it "averages OI across all strikes in the chain" do
      chain = {
        'AAPL_C1' => { 'open_interest' => 100 },
        'AAPL_C2' => { 'openInterest' => 200 },
        'AAPL_C3' => { 'oi' => 300 }
      }
      expect(described_class.avg_open_interest(chain)).to eq(200.0)
    end

    it "ignores strikes with no OI key" do
      chain = {
        'AAPL_C1' => { 'open_interest' => 100 },
        'AAPL_C2' => { 'greeks' => { 'iv' => 0.3 } }, # no OI
        'AAPL_C3' => { 'openInterest' => 300 }
      }
      expect(described_class.avg_open_interest(chain)).to eq(200.0)
    end

    it "returns nil for an empty chain" do
      expect(described_class.avg_open_interest({})).to be_nil
    end

    it "returns nil for nil input" do
      expect(described_class.avg_open_interest(nil)).to be_nil
    end

    it "returns nil when no strike has an OI value" do
      chain = { 'AAPL_C1' => { 'greeks' => { 'iv' => 0.3 } } }
      expect(described_class.avg_open_interest(chain)).to be_nil
    end
  end

  describe ".avg_bid_ask_spread_pct" do
    it "averages the (ask-bid)/mid spread across strikes" do
      # Strike 1: bid=1.00, ask=1.10, mid=1.05, spread=0.10/1.05 ≈ 0.0952
      # Strike 2: bid=2.00, ask=2.20, mid=2.10, spread=0.20/2.10 ≈ 0.0952
      chain = {
        'AAPL_C1' => { 'latestQuote' => { 'bp' => 1.00, 'ap' => 1.10 } },
        'AAPL_C2' => { 'latestQuote' => { 'bp' => 2.00, 'ap' => 2.20 } }
      }
      spread = described_class.avg_bid_ask_spread_pct(chain)
      expect(spread).to be_within(0.001).of(0.0952)
    end

    it "accepts the snake_case REST shape (latest_quote, bid_price, ask_price)" do
      chain = {
        'AAPL_C1' => { 'latest_quote' => { 'bid_price' => 1.0, 'ask_price' => 1.1 } }
      }
      spread = described_class.avg_bid_ask_spread_pct(chain)
      expect(spread).to be_within(0.001).of(0.0952)
    end

    it "returns nil for an empty chain" do
      expect(described_class.avg_bid_ask_spread_pct({})).to be_nil
    end

    it "returns nil for nil input" do
      expect(described_class.avg_bid_ask_spread_pct(nil)).to be_nil
    end

    it "returns nil when no strike has a populated quote" do
      chain = { 'AAPL_C1' => { 'greeks' => { 'iv' => 0.3 } } }
      expect(described_class.avg_bid_ask_spread_pct(chain)).to be_nil
    end

    it "ignores strikes with zero or missing bid/ask" do
      chain = {
        'AAPL_C1' => { 'latestQuote' => { 'bp' => 0, 'ap' => 1.10 } },  # bid=0 → bad
        'AAPL_C2' => { 'latestQuote' => { 'bp' => 2.00, 'ap' => 2.20 } }
      }
      expect(described_class.avg_bid_ask_spread_pct(chain)).to be_within(0.001).of(0.0952)
    end
  end

  describe "liquidity criterion handlers" do
    let(:passing_scores) { { avg_open_interest: 200.0, avg_bid_ask_spread_pct: 0.08 } }
    let(:failing_scores) { { avg_open_interest: 50.0,  avg_bid_ask_spread_pct: 0.30 } }
    let(:nil_scores)     { { avg_open_interest: nil,   avg_bid_ask_spread_pct: nil   } }

    it "min_open_interest: 100 passes when avg OI is 200" do
      handler = described_class::CRITERION_HANDLERS[:min_open_interest]
      expect(handler.call(passing_scores, 100)).to be true
    end

    it "min_open_interest: 100 fails when avg OI is 50" do
      handler = described_class::CRITERION_HANDLERS[:min_open_interest]
      expect(handler.call(failing_scores, 100)).to be false
    end

    it "min_open_interest passes when OI score is nil (free-tier data missing)" do
      handler = described_class::CRITERION_HANDLERS[:min_open_interest]
      expect(handler.call(nil_scores, 100)).to be true
    end

    it "max_bid_ask_spread_pct: 0.10 passes when avg spread is 0.08" do
      handler = described_class::CRITERION_HANDLERS[:max_bid_ask_spread_pct]
      expect(handler.call(passing_scores, 0.10)).to be true
    end

    it "max_bid_ask_spread_pct: 0.10 fails when avg spread is 0.30" do
      handler = described_class::CRITERION_HANDLERS[:max_bid_ask_spread_pct]
      expect(handler.call(failing_scores, 0.10)).to be false
    end

    it "max_bid_ask_spread_pct passes when spread score is nil (free-tier data missing)" do
      handler = described_class::CRITERION_HANDLERS[:max_bid_ask_spread_pct]
      expect(handler.call(nil_scores, 0.10)).to be true
    end
  end

  describe ".pct_change" do
    it "returns 0.0 with fewer than 2 closes (need 2 points to compute any change)" do
      expect(described_class.pct_change([], 7)).to eq(0.0)
      expect(described_class.pct_change([100.0], 7)).to eq(0.0)
    end

    it "computes the percent change from n closes ago" do
      closes = [100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 110.0]
      # n=7 → 110/100 - 1 = 10%
      expect(described_class.pct_change(closes, 7)).to eq(10.0)
    end

    it "clamps n to available data so a 7d request with only 4 closes returns the 3-day change" do
      # 4 closes, n clamped to 3 → reference bar is closes[-(3+1)] = closes[0] = 100
      # change = (121/100 - 1) * 100 = 21%
      closes = [100.0, 105.0, 110.0, 121.0]
      expect(described_class.pct_change(closes, 7)).to eq(21.0)
    end

    it "returns 0.0 when the reference close is 0" do
      closes = [0.0, 0.0, 0.0, 0.0, 100.0]
      expect(described_class.pct_change(closes, 7)).to eq(0.0)
    end
  end

  describe ".avg_dollar_volume" do
    it "returns 0.0 for an empty bars list" do
      expect(described_class.avg_dollar_volume(ticker: 'X', bars: [])).to eq(0.0)
    end

    it "returns 0.0 when bars is nil" do
      expect(described_class.avg_dollar_volume(ticker: 'X', bars: nil)).to eq(0.0)
    end

    it "computes average daily dollar volume (close * volume per bar)" do
      # Two bars: (100 * 10) + (110 * 20) = 3200 / 2 = 1600
      bars = [
        { 'c' => 100.0, 'v' => 10 },
        { 'c' => 110.0, 'v' => 20 }
      ]
      expect(described_class.avg_dollar_volume(ticker: 'X', bars: bars)).to eq(1600.0)
    end
  end

  describe ".score" do
    let(:snapshot) do
      {
        ticker: 'AAPL',
        # 4 daily closes: 100, 105, 110, 121
        bars: [
          { 'c' => 100.0, 'v' => 1_000_000, 't' => '2026-08-25' },
          { 'c' => 105.0, 'v' => 1_000_000, 't' => '2026-08-26' },
          { 'c' => 110.0, 'v' => 1_000_000, 't' => '2026-08-27' },
          { 'c' => 121.0, 'v' => 1_000_000, 't' => '2026-08-28' }
        ],
        option_snapshot: nil,
        news: []
      }
    end

    it "always sets pct_change_7d when >= 2 closes are available" do
      # 4 closes: [100, 105, 110, 121]. n=7 clamped to 3 → closes[0]=100 vs 121 = 21%
      scores = described_class.score(snapshot, {})
      expect(scores[:pct_change_7d]).to eq(21.0)
    end

    it "sets avg_dollar_volume keyed under the new name (renamed from market_cap)" do
      scores = described_class.score(snapshot, {})
      # 4 bars × (close × volume): 100M + 105M + 110M + 121M = 436M / 4 = 109M
      expect(scores[:avg_dollar_volume]).to be_within(0.01).of(109_000_000.0)
      expect(scores).not_to have_key(:market_cap)
    end

    it "returns avg_dollar_volume: 0.0 and zero news counts when no data is available" do
      scores = described_class.score({ ticker: 'X', bars: [], news: [] }, {})
      expect(scores[:avg_dollar_volume]).to eq(0.0)
      expect(scores[:news_earnings_keyword_count]).to eq(0)
      expect(scores[:news_insider_buy_count]).to eq(0)
      expect(scores[:news_insider_buy_value_usd]).to eq(0.0)
    end

    it "skips the EDGAR HTTP call when filter_type is not 'insider'" do
      # Default behaviour: every non-insider filter used to call
      # EdgarClient.insider_buy_summary per ticker per chunk, even
      # though the score was discarded. That dominated the wall
      # time of the volatility + earnings filters. With filter_type
      # passed through, only the insider filter pays for it.
      allow(described_class).to receive(:edgar_scores).and_call_original
      described_class.score(snapshot, {}, filter_type: 'volatility')
      expect(described_class).not_to have_received(:edgar_scores)
    end

    it "calls edgar_scores when filter_type is 'insider'" do
      allow(described_class).to receive(:edgar_scores).and_return(
        edgar_insider_buy_count: 5, edgar_insider_buy_value_usd: 1_000_000.0
      )
      scores = described_class.score(snapshot, {}, filter_type: 'insider')
      expect(scores[:edgar_insider_buy_count]).to eq(5)
      expect(scores[:edgar_insider_buy_value_usd]).to eq(1_000_000.0)
    end

    it "accepts a nil filter_type (backwards compat) without calling edgar" do
      allow(described_class).to receive(:edgar_scores).and_call_original
      described_class.score(snapshot, {}, filter_type: nil)
      expect(described_class).not_to have_received(:edgar_scores)
    end
  end

  describe ".meets_criteria?" do
    it "honors avg_dollar_volume_min against the renamed score key" do
      scores = { avg_dollar_volume: 150_000_000.0 }
      expect(described_class.meets_criteria?(scores, avg_dollar_volume_min: 100_000_000)).to be true
      expect(described_class.meets_criteria?(scores, avg_dollar_volume_min: 200_000_000)).to be false
    end

    it "treats unknown criteria as a pass-through" do
      scores = {}
      expect(described_class.meets_criteria?(scores, some_future_filter: 1)).to be true
    end

    it "treats a missing pct_change_7d as 0 (so 0 < min fails)" do
      scores = { avg_dollar_volume: 100_000_000.0 }
      expect(described_class.meets_criteria?(scores, pct_change_7d_min: 5)).to be false
    end

    it "honors rsi_max — passes when score is below the threshold" do
      scores = { rsi_3: 25.0 }
      expect(described_class.meets_criteria?(scores, rsi_max: 30)).to be true
      expect(described_class.meets_criteria?(scores, rsi_max: 20)).to be false
    end

    it "treats a missing rsi_3 as if it were neutral-50 (fails rsi_max:30 to be safe)" do
      # nil RSI → we can't prove the ticker is oversold, so reject.
      expect(described_class.meets_criteria?({}, rsi_max: 30)).to be false
      # But rsi_min: 30 would also reject nil (can't prove it's > 30).
      expect(described_class.meets_criteria?({}, rsi_min: 30)).to be false
    end

    it "honors has_options — passes when option chain returned at least one snapshot" do
      expect(described_class.meets_criteria?({ has_options: true }, has_options: true)).to be true
      expect(described_class.meets_criteria?({ has_options: false }, has_options: true)).to be false
      expect(described_class.meets_criteria?({}, has_options: true)).to be false
    end

    it "honors earnings_within_days_max — passes when any recent news has an earnings keyword" do
      expect(described_class.meets_criteria?({ news_earnings_keyword_count: 0 },
                                             earnings_within_days_max: 5)).to be false
      expect(described_class.meets_criteria?({ news_earnings_keyword_count: 1 },
                                             earnings_within_days_max: 5)).to be true
    end

    it "honors insider_buys_min and insider_value_min together (EDGAR-backed scores)" do
      scores = { edgar_insider_buy_count: 2, edgar_insider_buy_value_usd: 500_000 }
      expect(described_class.meets_criteria?(scores, insider_buys_min: 3)).to be false
      expect(described_class.meets_criteria?(scores, insider_buys_min: 2, insider_value_min: 1_000_000)).to be false
      scores2 = { edgar_insider_buy_count: 3, edgar_insider_buy_value_usd: 2_000_000 }
      expect(described_class.meets_criteria?(scores2, insider_buys_min: 3, insider_value_min: 1_000_000)).to be true
    end
  end

  describe ".rsi" do
    it "returns nil when not enough data is available" do
      expect(described_class.rsi([100.0, 101.0], period: 7)).to be_nil
      expect(described_class.rsi([], period: 7)).to be_nil
    end

    it "returns ~100 for a sustained uptrend" do
      closes = (1..15).map { |i| 100.0 + i }
      rsi = described_class.rsi(closes, period: 7)
      expect(rsi).to be > 90
    end

    it "returns ~0 for a sustained downtrend" do
      closes = (1..15).map { |i| 100.0 - i }
      rsi = described_class.rsi(closes, period: 7)
      expect(rsi).to be < 10
    end

    it "returns 50 when prices are flat (no gains, no losses)" do
      closes = Array.new(15, 100.0)
      rsi = described_class.rsi(closes, period: 7)
      expect(rsi).to eq(50.0)
    end
  end

  describe ".news_earnings_keyword_count" do
    it "returns 0 for an empty list" do
      expect(TickerSelector::NewsProxies.earnings_keyword_count([])).to eq(0)
    end

    it "counts headlines matching earnings keywords (case-insensitive)" do
      items = [
        { 'headline' => 'Apple Reports Strong Earnings, Beats EPS' },
        { 'headline' => "Analyst upgrades Apple's price target" },
        { 'headline' => 'Tesla Q3 Earnings Disappoint' },
        { 'headline' => 'Market commentary on rates' }
      ]
      expect(TickerSelector::NewsProxies.earnings_keyword_count(items)).to eq(2)
    end

    it "matches fiscal year/quarter references" do
      items = [{ 'headline' => 'Microsoft announces fiscal year guidance update' }]
      expect(TickerSelector::NewsProxies.earnings_keyword_count(items)).to eq(1)
    end
  end

  describe ".news_insider_buy_count" do
    it "returns 0 for an empty list" do
      expect(TickerSelector::NewsProxies.insider_buy_count([])).to eq(0)
    end

    it "counts headlines matching insider + buy/purchase" do
      items = [
        { 'headline' => 'Insider buys $5M of company stock' },
        { 'headline' => 'Insider sells shares — bearish signal' },
        { 'headline' => 'Market moves on macro news' }
      ]
      expect(TickerSelector::NewsProxies.insider_buy_count(items)).to eq(1)
    end

    it "matches 'purchased' and 'purchase'" do
      items = [
        { 'headline' => 'Insider purchased 10,000 shares' },
        { 'headline' => 'Multiple insider purchases at TechCo' }
      ]
      expect(TickerSelector::NewsProxies.insider_buy_count(items)).to eq(2)
    end
  end

  describe ".news_insider_buy_value_usd" do
    it "returns 0.0 for an empty list" do
      expect(TickerSelector::NewsProxies.insider_buy_value_usd([])).to eq(0.0)
    end

    it "sums $K, $M, $B amounts across insider-buy headlines" do
      items = [
        { 'headline' => 'Insider buys $5M of stock' },
        { 'headline' => 'CEO insider purchase of $250,000' },
        { 'headline' => 'Insider buys $1.2B in shares' },
        { 'headline' => 'Insider sells shares' } # not a buy, ignored
      ]
      total = TickerSelector::NewsProxies.insider_buy_value_usd(items)
      # 5M + 250k + 1.2B = 1,205,250,000
      expect(total).to be_within(1.0).of(1_205_250_000.0)
    end

    it "handles a single insider-buy headline with K suffix" do
      items = [{ 'headline' => 'Insider buys $750K of company stock' }]
      expect(TickerSelector::NewsProxies.insider_buy_value_usd(items)).to eq(750_000.0)
    end
  end

  describe ".recent_news" do
    let(:now) { Time.utc(2026, 8, 29, 12, 0, 0) }

    before { allow(Time).to receive(:now).and_return(now) }

    it "filters out items older than the window" do
      items = [
        { 'headline' => 'a', 'created_at' => (now - (1 * 86_400)).iso8601 },    # 1 day ago: keep
        { 'headline' => 'b', 'created_at' => (now - (5 * 86_400)).iso8601 },    # 5 days ago: keep
        { 'headline' => 'c', 'created_at' => (now - (8 * 86_400)).iso8601 },    # 8 days ago: drop
        { 'headline' => 'd', 'created_at' => (now - (30 * 86_400)).iso8601 }    # 30 days ago: drop
      ]
      kept = TickerSelector::NewsProxies.recent(items, within_days: 7)
      expect(kept.map { |n| n['headline'] }).to eq(%w[a b])
    end

    it "returns [] for empty input" do
      expect(TickerSelector::NewsProxies.recent([], within_days: 7)).to eq([])
    end

    it "tolerates items with missing/blank created_at" do
      items = [
        { 'headline' => 'a', 'created_at' => nil },
        { 'headline' => 'b' },
        { 'headline' => 'c', 'created_at' => (now - (1 * 86_400)).iso8601 }
      ]
      kept = TickerSelector::NewsProxies.recent(items, within_days: 7)
      expect(kept.map { |n| n['headline'] }).to eq(['c'])
    end

    it "tolerates items with malformed created_at (returns false for them)" do
      items = [
        { 'headline' => 'a', 'created_at' => 'not a date' },
        { 'headline' => 'b', 'created_at' => (now - (1 * 86_400)).iso8601 }
      ]
      kept = TickerSelector::NewsProxies.recent(items, within_days: 7)
      expect(kept.map { |n| n['headline'] }).to eq(['b'])
    end
  end
end
# rubocop:enable Metrics/BlockLength
