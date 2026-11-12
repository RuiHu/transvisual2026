require "rails_helper"

RSpec.describe "Shipment query API", type: :request do
  it "returns 404 for an unknown shipment" do
    get "/api/v1/shipments/TV-UNKNOWN/timeline"
    expect(response).to have_http_status(:not_found)
    expect(json_body["error"]).to eq("Shipment not found")
  end

  it "orders a late/out-of-order event into the timeline without changing the terminal status" do
    post_event(event_id: "ooo-spec-3", shipment_reference: "TV-OOO-SPEC",
               status: "delivered", event_timestamp: "2026-07-03T12:00:00Z")
    post_event(event_id: "ooo-spec-1", shipment_reference: "TV-OOO-SPEC",
               status: "created", event_timestamp: "2026-07-01T12:00:00Z")
    post_event(event_id: "ooo-spec-2", shipment_reference: "TV-OOO-SPEC",
               status: "picked_up", event_timestamp: "2026-07-02T12:00:00Z")

    get "/api/v1/shipments/TV-OOO-SPEC/timeline"
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(body["current_status"]).to eq("delivered")
    expect(body["events"].map { |event| event["status"] })
      .to eq(%w[created picked_up delivered])
    expect(body["events"].map { |event| event["event_timestamp"] })
      .to eq(body["events"].map { |event| event["event_timestamp"] }.sort)
  end

end
