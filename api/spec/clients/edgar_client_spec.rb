# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EdgarClient do
  describe '.ticker_to_cik' do
    it 'returns the 10-digit zero-padded CIK for a known ticker' do
      body = {
        '0' => { 'cik_str' => 320193, 'ticker' => 'AAPL', 'title' => 'Apple Inc.' },
        '1' => { 'cik_str' => 789019, 'ticker' => 'MSFT', 'title' => 'Microsoft' }
      }
      stub_request(:get, 'https://www.sec.gov/files/company_tickers.json')
        .to_return(status: 200, body: body.to_json,
                   headers: { 'content-type' => 'application/json' })
      Rails.cache.clear
      expect(described_class.ticker_to_cik('AAPL')).to eq('0000320193')
      expect(described_class.ticker_to_cik('aapl')).to eq('0000320193')
      expect(described_class.ticker_to_cik('MSFT')).to eq('0000789019')
    end

    it 'returns nil for an unknown ticker' do
      stub_request(:get, 'https://www.sec.gov/files/company_tickers.json')
        .to_return(status: 200, body: { '0' => { 'ticker' => 'AAPL', 'cik_str' => 320193 } }.to_json,
                   headers: { 'content-type' => 'application/json' })
      Rails.cache.clear
      expect(described_class.ticker_to_cik('ZZZZ')).to be_nil
    end
  end

  describe '.recent_form4_filings' do
    let(:submissions) do
      {
        'cik' => '320193',
        'filings' => {
          'recent' => {
            'form' => ['4', '4', '4', '10-K', '4'],
            'filingDate' => [
              (Date.today - 2).iso8601,
              (Date.today - 5).iso8601,
              (Date.today - 30).iso8601,
              (Date.today - 40).iso8601,
              (Date.today - 90).iso8601
            ],
            'accessionNumber' => ['0001', '0002', '0003', '0004', '0005'],
            'primaryDocument' => ['wf1.xml', 'wf2.xml', 'wf3.xml', 'wk.xml', 'wf5.xml'],
            'reportingPerson' => [
              { 'name' => 'Cook T.', 'isDirector' => true },
              { 'name' => 'Luca M.', 'isOfficer' => true },
              { 'name' => 'Jeff W.', 'isDirector' => false },
              nil,
              { 'name' => 'Old Buyer', 'isDirector' => true }
            ]
          }
        }
      }
    end

    it 'returns only Form 4 filings within the lookback window' do
      stub_request(:get, 'https://data.sec.gov/submissions/CIK0000320193.json')
        .to_return(status: 200, body: submissions.to_json,
                   headers: { 'content-type' => 'application/json' })
      Rails.cache.clear

      filings = described_class.recent_form4_filings('0000320193', since: Date.today - 30)
      expect(filings.size).to eq(3)
      expect(filings.map { |f| f[:accession] }).to eq(['0001', '0002', '0003'])
      expect(filings.first[:reporter]).to eq('Cook T.')
      expect(filings.first[:is_direct]).to be true
    end

    it 'returns [] when the CIK is blank' do
      expect(described_class.recent_form4_filings(nil, since: Date.today)).to eq([])
    end
  end

  describe '.insider_buy_summary' do # rubocop:disable Metrics/BlockLength
    let(:tickers_index) { { '0' => { 'cik_str' => 320193, 'ticker' => 'AAPL' } } }

    it 'returns 0/{} when the ticker is unknown' do
      stub_request(:get, 'https://www.sec.gov/files/company_tickers.json')
        .to_return(status: 200, body: tickers_index.to_json,
                   headers: { 'content-type' => 'application/json' })
      Rails.cache.clear

      result = described_class.insider_buy_summary('ZZZZ', lookback_days: 14)
      expect(result[:count]).to eq(0)
      expect(result[:total_value_usd]).to eq(0.0)
      expect(result[:transactions]).to eq([])
    end

    it 'returns a Form 4 buy transaction parsed from XML' do
      stub_request(:get, 'https://www.sec.gov/files/company_tickers.json')
        .to_return(status: 200, body: tickers_index.to_json,
                   headers: { 'content-type' => 'application/json' })
      stub_request(:get, 'https://data.sec.gov/submissions/CIK0000320193.json')
        .to_return(status: 200, body: {
          'filings' => { 'recent' => {
            'form' => ['4'],
            'filingDate' => [Date.today.iso8601],
            'accessionNumber' => ['0000320193-24-000001'],
            'primaryDocument' => ['wf.xml'],
            'reportingPerson' => [{ 'name' => 'Cook T.', 'isDirector' => true }]
          } }
        }.to_json, headers: { 'content-type' => 'application/json' })

      form4_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <ownershipDocument>
          <reportingOwner>
            <reportingOwnerId>
              <rptOwnerName>Cook T.</rptOwnerName>
            </reportingOwnerId>
          </reportingOwner>
          <nonDerivativeTable>
            <nonDerivativeTransaction>
              <transactionDate><value>2024-01-15</value></transactionDate>
              <transactionCoding><transactionCode>P</transactionCode></transactionCoding>
              <securityTitle><value>Common Stock</value></securityTitle>
              <transactionAmounts>
                <transactionShares><value>5000</value></transactionShares>
                <transactionPricePerShare><value>190.50</value></transactionPricePerShare>
              </transactionAmounts>
            </nonDerivativeTransaction>
          </nonDerivativeTable>
        </ownershipDocument>
      XML
      # Stub the Form 4 XML fetch — the production code strips the
      # xsl* stylesheet prefix from `primaryDocument` so the request
      # hits the structured XML, not the HTML-rendered version.
      stub_request(:get, %r{https://www\.sec\.gov/Archives/}).to_return(
        status: 200, body: form4_xml,
        headers: { 'content-type' => 'application/xml' }
      )
      Rails.cache.clear

      result = described_class.insider_buy_summary('AAPL', lookback_days: 14)
      expect(result[:count]).to eq(1)
      expect(result[:total_value_usd]).to eq(5000 * 190.50)
      expect(result[:transactions].first[:insider]).to eq('Cook T.')
      expect(result[:transactions].first[:shares]).to eq(5000.0)
      expect(result[:transactions].first[:price_per_share]).to eq(190.50)
    end

    it 'ignores SALE transactions (transaction code S)' do
      stub_request(:get, 'https://www.sec.gov/files/company_tickers.json')
        .to_return(status: 200, body: tickers_index.to_json,
                   headers: { 'content-type' => 'application/json' })
      stub_request(:get, 'https://data.sec.gov/submissions/CIK0000320193.json')
        .to_return(status: 200, body: {
          'filings' => { 'recent' => {
            'form' => ['4'],
            'filingDate' => [Date.today.iso8601],
            'accessionNumber' => ['0000320193-24-000001'],
            'primaryDocument' => ['wf.xml'],
            'reportingPerson' => [{ 'name' => 'Cook T.' }]
          } }
        }.to_json, headers: { 'content-type' => 'application/json' })

      form4_xml = <<~XML
        <ownershipDocument>
          <nonDerivativeTable>
            <nonDerivativeTransaction>
              <transactionCoding><transactionCode>S</transactionCode></transactionCoding>
              <transactionDate><value>2024-01-15</value></transactionDate>
              <transactionAmounts>
                <transactionShares><value>5000</value></transactionShares>
                <transactionPricePerShare><value>190.50</value></transactionPricePerShare>
              </transactionAmounts>
            </nonDerivativeTransaction>
          </nonDerivativeTable>
        </ownershipDocument>
      XML
      stub_request(:get, %r{https://www\.sec\.gov/Archives/}).to_return(
        status: 200, body: form4_xml,
        headers: { 'content-type' => 'application/xml' }
      )
      Rails.cache.clear

      result = described_class.insider_buy_summary('AAPL', lookback_days: 14)
      expect(result[:count]).to eq(0)
      expect(result[:total_value_usd]).to eq(0.0)
    end
  end
end
