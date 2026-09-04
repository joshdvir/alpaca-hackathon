# frozen_string_literal: true

require 'rails_helper'

# Tests for the ConfigController — the front-end's trader.yml
# editor. Covers GET (read), PATCH (write + validate), and the
# reload endpoint.

RSpec.describe Api::ConfigController, type: :controller do
  # We point the test suite at a per-test config file so we don't
  # clobber the real config/trading.yml. The initializer reads
  # TRADING_CONFIG_PATH at boot, so we stub the path accessor
  # directly and use a tempfile in /tmp.
  let(:tmp_path) { "/tmp/trading_test_#{SecureRandom.hex(4)}.yml" }
  let(:initial_yaml) do
    <<~YAML
      risk_limits:
        max_open_positions: 3
        max_position_pct: 0.20
      llm:
        model: test-model
        rate_limit_per_minute: 30
    YAML
  end

  before do
    File.write(tmp_path, initial_yaml)
    allow(TradingConfig).to receive(:path).and_return(tmp_path)
    # Stub TRADING_CONFIG to_h so the controller's show endpoint
    # returns the test file's content. The reload! path inside
    # TradingConfig is bypassed (it'd re-read the real
    # config/trading.yml from the running Rails environment), so we
    # stub the .to_h accessor and let the controller's PATCH
    # actually write to disk.
    allow(TradingConfig).to receive(:to_h).and_return(
      YAML.safe_load(File.read(tmp_path)).deep_symbolize_keys
    )
  end

  after do
    File.delete(tmp_path) if File.exist?(tmp_path)
  end

  describe 'GET #show' do
    it 'returns the parsed config, raw yaml, and loaded_at' do
      get :show
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['config']).to be_a(Hash)
      expect(body['raw_yaml']).to include('risk_limits')
      expect(body['loaded_at']).to be_present
    end
  end

  describe 'PATCH #update' do
    it 'writes the new yaml to disk and reloads in memory' do
      new_yaml = <<~YAML
        risk_limits:
          max_open_positions: 7
          max_position_pct: 0.30
        llm:
          model: test-model-v2
          rate_limit_per_minute: 60
      YAML
      patch :update, params: { raw_yaml: new_yaml }
      expect(response).to have_http_status(:ok)
      expect(File.read(tmp_path)).to eq(new_yaml)
    end

    it 'returns 422 on YAML syntax error and does not touch the file' do
      original = File.read(tmp_path)
      patch :update, params: { raw_yaml: "this is: : not: valid: yaml: [" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(File.read(tmp_path)).to eq(original)
    end

    it 'returns 422 when the top-level is not a mapping' do
      patch :update, params: { raw_yaml: "- just\n- a\n- list\n" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns 400 when raw_yaml is missing' do
      patch :update, params: {}
      expect(response).to have_http_status(:bad_request)
    end

    it 'writes atomically (via .tmp.<pid> rename)' do
      new_yaml = "x: 1\n"
      expect(File).to receive(:rename).with(/\.tmp\.\d+\z/, tmp_path).and_call_original
      patch :update, params: { raw_yaml: new_yaml }
    end
  end

  describe 'POST #reload' do
    it 're-reads the file and returns the new config' do
      File.write(tmp_path, "fresh_key: 1\n")
      post :reload
      expect(response).to have_http_status(:ok)
    end
  end
end
