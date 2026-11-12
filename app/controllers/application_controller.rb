class ApplicationController < ActionController::API
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_bad_request
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private

  def render_bad_request(_error)
    render json: { error: "Bad request" }, status: :bad_request
  end

  def render_not_found(_error)
    render json: { error: "Shipment not found" }, status: :not_found
  end
end
