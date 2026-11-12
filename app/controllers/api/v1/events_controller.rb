module Api
  module V1
    class EventsController < ApplicationController
      # POST /api/v1/events
      #
      # Single: 201 inserted=1, 200 duplicate=true inserted=0, 422 validation,
      #         400 non-JSON / malformed body.
      # Batch:  {"events":[ ... ]} -> 200 {accepted, inserted, duplicates, failed}
      def create
        unless request.content_type.to_s.start_with?("application/json")
          return render json: { error: "Bad request" }, status: :bad_request
        end

        return create_batch if params[:events].present?

        permitted = params.permit(:event_id, :shipment_reference, :status, :event_timestamp)
        outcome, event = ingest!(permitted.to_h)

        if outcome == :inserted
          render json: event_json(event), status: :created
        else
          render json: event_json(event).merge(duplicate: true), status: :ok
        end
      rescue ActiveRecord::RecordInvalid => error
        render json: { errors: error.record.errors.to_hash }, status: 422
      end

      private

      def create_batch
        rows = params[:events]
        unless rows.is_a?(Array) && rows.any?
          return render json: { errors: { events: ["must be a non-empty array"] } }, status: 422
        end

        inserted = 0
        duplicates = 0
        failed = []

        rows.each do |row|
          attrs = row.permit(:event_id, :shipment_reference, :status, :event_timestamp).to_h
          begin
            outcome, _event = ingest!(attrs)
            outcome == :inserted ? inserted += 1 : duplicates += 1
          rescue ActiveRecord::RecordInvalid => error
            failed << { event_id: attrs[:event_id], errors: error.record.errors.to_hash }
          end
        end

        render json: {
          accepted: rows.size,
          inserted: inserted,
          duplicates: duplicates,
          failed: failed
        }, status: :ok
      end

      # Returns [:inserted, event] or [:duplicate, existing_event].
      def ingest!(attrs)
        result = nil
        ActiveRecord::Base.transaction do
          ensure_shipment!(attrs[:shipment_reference])
          result = [:inserted, Event.create!(attrs)]
        end
        result
      rescue ActiveRecord::RecordInvalid => error
        raise unless error.record.errors.of_kind?(:event_id, :taken)

        [:duplicate, Event.find_by!(event_id: attrs[:event_id])]
      rescue ActiveRecord::RecordNotUnique
        [:duplicate, Event.find_by!(event_id: attrs[:event_id])]
      end

      # First event for a reference creates the shipment in the same
      # transaction. The reference UNIQUE index arbitrates concurrent creation;
      # losing thread re-reads instead of surfacing a duplicate-shipment error.
      def ensure_shipment!(reference)
        return if reference.blank?
        return if Shipment.exists?(reference: reference)

        # Savepoint (requires_new) is essential: a unique violation on the
        # reference index would otherwise abort the whole outer transaction and
        # every later query would fail with "current transaction is aborted".
        Shipment.transaction(requires_new: true) { Shipment.create!(reference: reference) }
      rescue ActiveRecord::RecordNotUnique
        Shipment.find_by!(reference: reference)
      end

      def event_json(event)
        {
          event_id: event.event_id,
          shipment_reference: event.shipment_reference,
          status: event.status,
          event_timestamp: event.event_timestamp
        }
      end
    end
  end
end
