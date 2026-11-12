#!/usr/bin/env ruby
# EXPECTED_CMD — independent oracle.
# Reads only carrier_events.csv using the Ruby stdlib (CSV/JSON).
# It intentionally does NOT require the Rails app or reuse any model/query code.
require "csv"
require "json"

rows = CSV.read("carrier_events.csv", headers: true, encoding: "bom|utf-8").map(&:to_h)

seen = {}
unique = rows.select { |row| seen[row["event_id"]] ? false : (seen[row["event_id"]] = true) }

by_ship = unique.group_by { |row| row["shipment_reference"] }

shipments = by_ship.keys.sort.map do |reference|
  events = by_ship[reference].sort_by { |event| [event["event_timestamp"], event["event_id"]] }
  latest = events.last
  {
    "shipment_reference" => reference,
    "current_status" => latest["status"],
    "event_count" => events.size,
    "latest_event_timestamp" => latest["event_timestamp"],
    "timeline" => events.map do |event|
      {
        "event_id" => event["event_id"],
        "status" => event["status"],
        "event_timestamp" => event["event_timestamp"]
      }
    end
  }
end

breakdown = Hash.new(0)
shipments.each { |shipment| breakdown[shipment["current_status"]] += 1 }

result = {
  "total_shipments" => shipments.size,
  "total_events" => unique.size,
  "duplicate_event_ids" => rows.size - unique.size,
  "status_breakdown" => breakdown,
  "shipments" => shipments
}

File.write(".spec/expected_state.json", JSON.pretty_generate(result))
puts "expected_state.json written: #{shipments.size} shipments, #{unique.size} events"
