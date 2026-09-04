# frozen_string_literal: true

module Api
  class BaseController < ActionController::API
    rescue_from ActiveRecord::RecordNotFound do |e|
      render json: { error: 'not_found', message: e.message }, status: :not_found
    end

    rescue_from ActionController::ParameterMissing do |e|
      render json: { error: 'bad_request', message: e.message }, status: :bad_request
    end

    rescue_from StandardError do |e|
      Rails.logger.error "[api] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      render json: { error: 'internal_server_error', message: e.message }, status: :internal_server_error
    end
  end
end
