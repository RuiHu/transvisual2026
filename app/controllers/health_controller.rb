class HealthController < ApplicationController
  # Used by the Compose web healthcheck so `docker compose up --wait` really waits
  # for a working DB connection, not just for a listening socket.
  def show
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "ok", db: "up" }
  rescue StandardError => error
    render json: { status: "degraded", db: "down", error: error.class.name },
           status: :service_unavailable
  end
end
