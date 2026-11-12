require "csv"
require "json"
require "net/http"
require "uri"

namespace :replay do
  desc "Replay carrier_events.csv concurrently and verify against .spec/expected_state.json"
  task full: :environment do
    base_url = ENV.fetch("BASE_URL", "http://127.0.0.1:3000")
    seed = Integer(ENV.fetch("SEED", "42"))
    concurrency = [Integer(ENV.fetch("CONCURRENCY", "10")), 1].max

    rows = CSV.read("carrier_events.csv", headers: true, encoding: "bom|utf-8").map(&:to_h)
    file_unique = rows.map { |row| row["event_id"] }.uniq.size
    file_duplicates = rows.size - file_unique
    shuffled = rows.shuffle(random: Random.new(seed))

    puts "seed=#{seed} threads=#{concurrency} shuffled=true"
    puts "input rows=#{rows.size} unique_event_ids=#{file_unique}"
    puts "duplicates=#{file_duplicates}"

    before_events = Event.count
    before_shipments = Shipment.count

    queue = Queue.new
    shuffled.each { |row| queue << row }

    mutex = Mutex.new
    new_count = 0
    duplicate_count = 0
    error_count = 0
    errors = []

    uri = URI.join(base_url, "/api/v1/events")

    workers = Array.new(concurrency) do
      Thread.new do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          loop do
            row = begin
              queue.pop(true)
            rescue ThreadError
              break
            end

            request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
            request.body = JSON.generate(
              row.slice("event_id", "shipment_reference", "status", "event_timestamp")
            )
            response = http.request(request)
            code = response.code.to_i

            mutex.synchronize do
              if code == 201
                new_count += 1
              elsif code == 200
                duplicate_count += 1
              else
                error_count += 1
                errors << "HTTP #{code} for #{row["event_id"]}" if errors.size < 5
              end
            end
          end
        end
      end
    end

    workers.each(&:join)

    after_events = Event.count
    after_shipments = Shipment.count

    puts "#{new_count} new, #{duplicate_count} duplicates"
    puts "0 new events" if new_count.zero?
    puts "events #{before_events} -> #{after_events}; shipments #{before_shipments} -> #{after_shipments}"
    puts "errors=#{error_count}" if error_count.positive?
    errors.each { |message| puts "ERROR #{message}" }

    ok = verify_against_expected(base_url)
    exit 1 if !ok || error_count.positive?
  end

  desc "Verify current API state against .spec/expected_state.json without delivering events"
  task verify: :environment do
    base_url = ENV.fetch("BASE_URL", "http://127.0.0.1:3000")
    exit 1 unless verify_against_expected(base_url)
  end
end

def verify_against_expected(base_url)
  expected_path = ".spec/expected_state.json"
  abort "missing #{expected_path}; run EXPECTED_CMD first" unless File.exist?(expected_path)

  expected = JSON.parse(File.read(expected_path))
  verified = 0
  failures = []

  expected.fetch("shipments").each do |expected_shipment|
    reference = expected_shipment.fetch("shipment_reference")
    response = Net::HTTP.get_response(
      URI.join(base_url, "/api/v1/shipments/#{URI.encode_www_form_component(reference)}/timeline")
    )

    if response.code.to_i != 200
      failures << "#{reference}: HTTP #{response.code}"
      next
    end

    actual = JSON.parse(response.body)
    expected_timeline = expected_shipment.fetch("timeline")
                                         .map { |e| [e["event_id"], e["status"], e["event_timestamp"]] }
    actual_timeline = actual.fetch("events", [])
                            .map { |e| [e["event_id"], e["status"], e["event_timestamp"]] }

    if actual["current_status"] == expected_shipment["current_status"] &&
       actual_timeline == expected_timeline
      verified += 1
    else
      failures << "#{reference}: mismatch"
    end
  end

  total = expected.fetch("total_shipments")
  failures.first(10).each { |message| puts "FAIL #{message}" }
  puts "#{verified}/#{total} shipments verified"
  failures.empty?
end
