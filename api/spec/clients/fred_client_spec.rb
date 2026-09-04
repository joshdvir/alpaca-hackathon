# frozen_string_literal: true

require 'rails_helper'

# FredClient — public CSV endpoint, no API key required.
# Spec covers the parsing contract (last non-"." row, float
# coercion, missing-data handling) and the failure modes
# (non-200, empty body, circuit-breaker open).
RSpec.describe FredClient do
  let(:series_ids) { %w[DGS10 VIXCLS] }
  let(:client) { described_class.new }

  before do
    # The FRED client wraps every HTTP call in a shared rate limiter
    # + circuit breaker (in the :fred namespace). In the test env
    # we don't want real circuit state to bleed across examples, so
    # we stub both to pass through to the underlying call.
    allow(RATE_LIMITERS[:fred]).to receive(:with_limit).and_yield
    allow(CIRCUIT_BREAKERS[:fred]).to receive(:call).and_yield
  end

  describe '#latest' do
    it 'returns {} when series_ids is blank' do
      expect(client.latest([])).to eq({})
      expect(client.latest(nil)).to eq({})
    end

    it 'fetches the latest observation from the public CSV endpoint' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
        .to_return(
          status: 200,
          body: "observation_date,DGS10\n2026-08-27,4.20\n2026-08-28,4.45\n"
        )

      result = client.latest(['DGS10'])
      expect(result['DGS10']).to eq(date: '2026-08-28', value: 4.45)
    end

    it 'picks the LAST non-`.` row in the CSV (FRED publishes "." for missing values)' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=VIXCLS')
        .to_return(
          status: 200,
          body: "observation_date,VIXCLS\n2026-08-27,22.5\n2026-08-28,.\n2026-08-29,23.1\n"
        )

      result = client.latest(['VIXCLS'])
      # Should pick 2026-08-29 (23.1) — the last non-missing value,
      # skipping the 2026-08-28 "." row.
      expect(result['VIXCLS']).to eq(date: '2026-08-29', value: 23.1)
    end

    it 'returns nil for a series whose CSV has only "." rows' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
        .to_return(status: 200, body: "observation_date,DGS10\n2026-08-28,.\n2026-08-29,.\n")

      result = client.latest(['DGS10'])
      expect(result['DGS10']).to be_nil
    end

    it 'returns nil for a non-200 CSV response' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
        .to_return(status: 500, body: 'Internal Server Error')

      result = client.latest(['DGS10'])
      expect(result['DGS10']).to be_nil
    end

    it 'coerces CSV string values to floats' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
        .to_return(status: 200, body: "observation_date,DGS10\n2026-08-28,4.45\n")

      result = client.latest(['DGS10'])
      expect(result['DGS10'][:value]).to be_a(Float)
      expect(result['DGS10'][:value]).to eq(4.45)
    end

    it 'fetches multiple series in one .latest call' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
        .to_return(status: 200, body: "observation_date,DGS10\n2026-08-28,4.45\n")
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=T10Y2Y')
        .to_return(status: 200, body: "observation_date,T10Y2Y\n2026-08-28,0.25\n")

      result = client.latest(%w[DGS10 T10Y2Y])
      expect(result['DGS10']).to eq(date: '2026-08-28', value: 4.45)
      expect(result['T10Y2Y']).to eq(date: '2026-08-28', value: 0.25)
    end

    it 'returns nil for a connection error (Faraday wraps DNS / refused / etc.)' do
      stub_request(:get, 'https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
        .to_raise(Faraday::ConnectionFailed.new('DNS failure'))

      result = client.latest(['DGS10'])
      expect(result['DGS10']).to be_nil
    end
  end
end
