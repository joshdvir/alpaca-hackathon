# frozen_string_literal: true

# RubyLLM — multi-provider LLM configuration
# We use MiniMax via OpenAI-compatible endpoints.

require 'ruby_llm'

RubyLLM.configure do |config|
  # OpenAI-compatible adapter points to MiniMax
  config.openai_api_key  = ENV.fetch('MINIMAX_API_KEY')
  config.openai_api_base = ENV.fetch('MINIMAX_API_BASE', 'https://api.minimax.io/v1')

  config.anthropic_api_key = ENV.fetch('MINIMAX_API_KEY', nil)
  config.anthropic_api_base = ENV.fetch('ANTHROPIC_API_BASE', 'https://api.minimax.io/anthropic')

  # Default model and provider
  config.default_model = TradingConfig.fetch(:llm, :default_model)
  config.request_timeout = TradingConfig.fetch(:llm, :request_timeout_seconds)

  # Use the new acts_as API; suppress the "legacy acts_as API is deprecated"
  # warning that the railtie emits on every boot. We don't use any acts_as_*
  # macros ourselves, so the API path doesn't matter — we just need the
  # railtie to skip emitting the warning.
  config.use_new_acts_as = true
end

# Refresh the model registry from the live provider on every boot and
# persist it to the JSON file RubyLLM reads. Without this, models
# that exist on the MiniMax side but not in the bundled registry
# (e.g. `MiniMax-M3`) raise `RubyLLM::ModelNotFoundError` on first
# use. Re-fetching each boot makes the registry a moving target
# against the provider — no manual `models.refresh!` + `save_to_json`
# step is required when a new model goes live.
#
# We swallow any error from the refresh (e.g. provider unreachable,
# rate-limited) so a transient API outage at boot doesn't take the
# whole api process down. Without a registry, calls will fail with
# ModelNotFoundError at request time instead, which is a better
# failure mode than a 500 at boot.
Rails.application.config.after_initialize do
  begin
    RubyLLM.models.refresh!
    RubyLLM.models.save_to_json
    Rails.logger.info "[ruby_llm] refreshed model registry (#{RubyLLM.models.all.size} models)"
  rescue StandardError => e
    Rails.logger.warn "[ruby_llm] model registry refresh failed: #{e.class}: #{e.message}"
  end
end

