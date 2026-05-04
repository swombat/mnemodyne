class ApplicationController < ActionController::API
  before_action :authenticate_request

  rescue_from ActiveRecord::RecordNotFound,        with: :not_found
  rescue_from ActiveRecord::RecordInvalid,         with: :unprocessable_entity
  rescue_from ActionController::ParameterMissing,  with: :bad_request

  private

  def authenticate_request
    expected = ENV.fetch("AUTH_TOKEN", nil)
    if expected.blank?
      Rails.logger.warn "[mnemodyne] AUTH_TOKEN not set; refusing all requests."
      render json: { error: "server_misconfigured" }, status: :service_unavailable
      return
    end

    presented = bearer_token
    return if presented && ActiveSupport::SecurityUtils.secure_compare(presented, expected)

    render json: { error: "unauthorized" }, status: :unauthorized
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip : nil
  end

  def not_found(exception)
    render json: { error: "not_found", detail: exception.message }, status: :not_found
  end

  def unprocessable_entity(exception)
    render json: {
      error: "unprocessable_entity",
      detail: exception.message,
      errors: exception.record&.errors&.as_json
    }, status: :unprocessable_entity
  end

  def bad_request(exception)
    render json: { error: "bad_request", detail: exception.message }, status: :bad_request
  end
end
