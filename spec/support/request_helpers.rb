module RequestHelpers
  def post_event(event_id:, shipment_reference:, status:, event_timestamp:)
    post "/api/v1/events",
         params: {
           event_id: event_id,
           shipment_reference: shipment_reference,
           status: status,
           event_timestamp: event_timestamp
         }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def post_batch(events)
    post "/api/v1/events",
         params: { events: events }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def json_body
    JSON.parse(response.body)
  end
end

RSpec.configure do |config|
  config.include RequestHelpers, type: :request
end
