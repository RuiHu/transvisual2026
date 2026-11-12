module Api
  module V1
    class ShipmentsController < ApplicationController
      # GET /api/v1/shipments[?status=...]
      # No pagination (spec X-11 / plan trade-off #10); sorted by reference.
      def index
        status = params[:status].presence
        if status && !Event::VALID_STATUSES.include?(status)
          return render json: { error: "Invalid status filter" }, status: :bad_request
        end

        rows = Shipment.includes(:events).order(:reference).map do |shipment|
          events = shipment.events.to_a
          latest = events.max_by { |event| [event.event_timestamp, event.event_id] }
          {
            shipment_reference: shipment.reference,
            current_status: latest&.status,
            event_count: events.size,
            latest_event_timestamp: latest&.event_timestamp
          }
        end

        rows = rows.select { |row| row[:current_status] == status } if status

        render json: { shipments: rows, total: rows.size }
      end

      # GET /api/v1/shipments/:reference/timeline
      def timeline
        shipment = Shipment.find_by!(reference: params[:reference])
        events = shipment.events.order(:event_timestamp, :event_id).to_a

        render json: {
          shipment_reference: shipment.reference,
          current_status: events.last&.status,
          events: events.map do |event|
            {
              event_id: event.event_id,
              status: event.status,
              event_timestamp: event.event_timestamp
            }
          end
        }
      end
    end
  end
end
