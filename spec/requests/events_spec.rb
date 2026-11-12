require "rails_helper"

RSpec.describe "POST /api/v1/events", type: :request do
  it "returns 201 then 200 duplicate for the same event_id" do
    post_event(event_id: "dup-1", shipment_reference: "TV-DUP", status: "created",
               event_timestamp: "2026-07-01T00:00:00Z")
    expect(response).to have_http_status(:created)

    post_event(event_id: "dup-1", shipment_reference: "TV-DUP", status: "created",
               event_timestamp: "2026-07-01T00:00:00Z")
    expect(response).to have_http_status(:ok)
    expect(json_body["duplicate"]).to be(true)
    expect(Event.where(event_id: "dup-1").count).to eq(1)
  end

  it "keeps the first payload when the same event_id arrives with a different payload" do
    post_event(event_id: "fw-1", shipment_reference: "TV-FW", status: "created",
               event_timestamp: "2026-07-01T00:00:00Z")
    post_event(event_id: "fw-1", shipment_reference: "TV-FW", status: "delivered",
               event_timestamp: "2026-07-09T00:00:00Z")

    expect(response).to have_http_status(:ok)
    stored = Event.find_by!(event_id: "fw-1")
    expect(stored.status).to eq("created")
    expect(stored.event_timestamp).to eq("2026-07-01T00:00:00Z")
  end

  it "stores exactly one row under 12 concurrent posts of the same event_id" do
    payload = {
      event_id: "conc-spec-1",
      shipment_reference: "TV-CONC-SPEC",
      status: "created",
      event_timestamp: "2026-07-01T00:00:00Z"
    }
    statuses = []
    mutex = Mutex.new

    threads = Array.new(12) do
      Thread.new do
        Rails.application.executor.wrap do
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.post "/api/v1/events",
                       params: payload.to_json,
                       headers: { "CONTENT_TYPE" => "application/json" }
          mutex.synchronize { statuses << session.response.status }
        end
      end
    end
    threads.each(&:join)

    expect(Event.where(event_id: "conc-spec-1").count).to eq(1)
    expect(statuses.count(201)).to eq(1)
    expect(statuses.count(200)).to eq(11)
    expect(statuses.all? { |code| code < 500 }).to be(true)
  end

  it "applies idempotency to every element of a repeated batch" do
    events = [
      { event_id: "batch-spec-1", shipment_reference: "TV-BATCH-SPEC",
        status: "created", event_timestamp: "2026-07-01T00:00:00Z" },
      { event_id: "batch-spec-2", shipment_reference: "TV-BATCH-SPEC",
        status: "picked_up", event_timestamp: "2026-07-02T00:00:00Z" },
      { event_id: "batch-spec-1", shipment_reference: "TV-BATCH-SPEC",
        status: "created", event_timestamp: "2026-07-01T00:00:00Z" }
    ]

    post_batch(events)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("accepted" => 3, "inserted" => 2, "duplicates" => 1)

    post_batch(events)
    expect(json_body).to include("accepted" => 3, "inserted" => 0, "duplicates" => 3)
    expect(Event.where(event_id: %w[batch-spec-1 batch-spec-2]).count).to eq(2)
  end

  it "leaves no side effects when a request is rejected with 422" do
    before_events = Event.count
    before_shipments = Shipment.count

    post "/api/v1/events",
         params: { event_id: "bad-spec-1", shipment_reference: "TV-BAD-SPEC" }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(422)
    expect(Event.count).to eq(before_events)
    expect(Shipment.count).to eq(before_shipments)
    expect(Shipment.find_by(reference: "TV-BAD-SPEC")).to be_nil
  end

  it "rejects a non-UTC timestamp with 422 and no side effects" do
    post_event(event_id: "tz-spec-1", shipment_reference: "TV-TZ",
               status: "created", event_timestamp: "2026-07-01T00:00:00+08:00")

    expect(response).to have_http_status(422)
    expect(json_body.dig("errors", "event_timestamp")).to be_present
    expect(Event.where(event_id: "tz-spec-1").count).to eq(0)
    expect(Shipment.where(reference: "TV-TZ").count).to eq(0)
  end
end
