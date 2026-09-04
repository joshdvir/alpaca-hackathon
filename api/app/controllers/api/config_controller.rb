# frozen_string_literal: true

module Api
  class ConfigController < BaseController
    # GET /api/config
    # Returns the live trading config (parsed + raw) so the front-end
    # editor can show the exact YAML the user is editing and validate
    # before saving.
    def show
      raw_yaml = File.exist?(TradingConfig.path) ? File.read(TradingConfig.path) : ''
      render json: {
        config: TRADING_CONFIG,
        raw_yaml: raw_yaml,
        loaded_from: TradingConfig.path,
        loaded_at: TradingConfig.last_loaded_at.iso8601
      }
    end

    # PATCH /api/config
    # Body: { "raw_yaml": "<full file contents>" }
    # Writes the new YAML to disk, parses + validates it, then reloads
    # in-memory. On success, broadcasts a live_updates:config event
    # so any connected editor refreshes. On parse error, returns 422
    # with the YAML error message and does NOT touch the file.
    def update
      raw_yaml = params[:raw_yaml].to_s
      if raw_yaml.empty?
        return render json: { error: 'bad_request', message: 'raw_yaml is required' }, status: :bad_request
      end

      # Validate before touching disk — parse the proposed content and
      # bail if it's not a Hash. We don't write to disk on a parse
      # error so the on-disk file always reflects a parseable config.
      begin
        parsed = YAML.safe_load(ERB.new(raw_yaml).result, aliases: true)
      rescue Psych::SyntaxError, Psych::DisallowedClass => e
        return render json: {
          error: 'unprocessable_entity',
          message: "YAML syntax error: #{e.message}",
          line: e.respond_to?(:line) ? e.line : nil
        }, status: :unprocessable_entity
      end

      unless parsed.is_a?(Hash)
        return render json: {
          error: 'unprocessable_entity',
          message: "Config must be a YAML mapping at the top level (got #{parsed.class})"
        }, status: :unprocessable_entity
      end

      # Atomic write — write to a tempfile then rename so a crash
      # mid-write can't leave a half-written config file.
      tmp_path = "#{TradingConfig.path}.tmp.#{Process.pid}"
      File.write(tmp_path, raw_yaml)
      File.rename(tmp_path, TradingConfig.path)

      # In-memory reload + broadcast. If this raises, we've already
      # written the new file, but the in-memory copy is stale — log
      # loudly so the next reload (or the next request) catches up.
      begin
        TradingConfig.reload!
      rescue StandardError => e
        Rails.logger.error "[api:config] reload after write failed: #{e.class}: #{e.message}"
        return render json: {
          error: 'internal_server_error',
          message: "File written but in-memory reload failed: #{e.message}"
        }, status: :internal_server_error
      end

      render json: {
        ok: true,
        loaded_from: TradingConfig.path,
        loaded_at: TradingConfig.last_loaded_at.iso8601,
        config: TRADING_CONFIG
      }
    end

    # POST /api/config/reload
    # Re-read the file from disk. Useful when an operator edited the
    # file directly (e.g. via a deploy script) and wants the running
    # process to pick it up without waiting for the watcher.
    def reload
      TradingConfig.reload!
      render json: {
        ok: true,
        loaded_from: TradingConfig.path,
        loaded_at: TradingConfig.last_loaded_at.iso8601,
        config: TRADING_CONFIG
      }
    end
  end
end
