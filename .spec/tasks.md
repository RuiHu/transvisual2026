# Shipment Events Service — Task Breakdown

> Phase 3 — Tasks | 2026-11-12
> Total implementation budget: 80 minutes. T10 (docs): 15 minutes.
> Every task is independently verifiable with a single command.

---

## Task Table

| ID | Title | Goal | Output files | Deps | Min | P | Parallel? | FR/SC trace |
|----|-------|------|-------------|------|-----|---|-----------|-------------|
| T01 | Project scaffold | Rails API + Docker Compose + PostgreSQL, server responds 200 | Dockerfile, compose.yaml, Gemfile, config/database.yml, config/routes.rb, config/application.rb, .dockerignore | — | 6 | P0 | No — all other tasks need the running stack | SC-14, FR-1 |
| T02 | Schema + models | Migrations create shipments and events tables with 3 indexes; model validations pass | db/migrate/…_create_shipments.rb, db/migrate/…_create_events.rb, app/models/shipment.rb, app/models/event.rb, db/schema.rb | T01 | 8 | P0 | No — T03/T04 need schema | FR-1, FR-2, FR-6, FR-8, SC-1 |
| T03 | POST /api/v1/events | Ingestion endpoint: valid→201, duplicate→200, invalid→422, non-UTC→422, concurrent-safe | app/controllers/api/v1/events_controller.rb, config/routes.rb (update) | T02 | 10 | P0 | Yes — with T04 (different controller, shared schema) | SC-1, SC-2, SC-3, SC-8, SC-9, FR-1–FR-5, FR-11 |
| T04 | GET /api/v1/shipments | Timeline (ordered events + current_status) + list (filter by status, sorted by reference) | app/controllers/api/v1/shipments_controller.rb, config/routes.rb (update) | T02 | 10 | P0 | Yes — with T03 (different controller, shared schema) | SC-4, SC-5, SC-6, SC-7, SC-16, SC-17, FR-6–FR-10 |
| T05 | Replay tooling | Rake task: shuffle CSV → concurrent POST → verify against expected_state.json → 310/310 | lib/tasks/replay.rake | T03, T04 | 10 | P0 | No — needs ingestion + query endpoints | SC-10, SC-11, SC-12, SC-13, FR-12–FR-14 |
| T06 | EXPECTED_CMD | Ruby script generates .spec/expected_state.json from CSV only — independent oracle, 310 shipments, 941 events | bin/generate_expected.rb | — | 5 | P0 | Yes — no dependency on the ingestion path; runs inside the app container | SC-5, SC-6, SC-10, spec §5 oracle independence |
| T07 | Test suite (RSpec) | Request/model specs pass against test DB; dev DB untouched after run | spec/rails_helper.rb, spec/spec_helper.rb, spec/support/request_helpers.rb, spec/requests/events_spec.rb, spec/requests/shipments_spec.rb | T03, T04 | 8 | P1 | No — needs controllers | SC-15 (pre-verify), Clause 4 partial |
| T08 | Test isolation verify | After tests, dev DB counts unchanged (941 events, 310 shipments); replay still passes | (verification-only — no new files) | T05, T07 | 3 | P1 | No — needs T05 + T07 completed | SC-15, Clause 4, Clause 5 |
| T09 | One-command demo + README | `./bin/demo` starts the stack and replay from clean state, prints 310/310; README documents exact commands | README.md, bin/demo | T01, T02, T03, T04, T05, T06 | 5 | P0 | No — needs everything | SC-14, Clause 6, Clause 7 |
| T10 | ADR + AI-usage + wrap up | ADR defends key trade-offs; AI-usage note documents tools + one thing AI got wrong; README finalized | ADR.md, AI_USAGE.md, README.md (update) | T09 | 15 | P1 | No — needs completed demo for honest AI-usage note | Brief: ADR, AI-usage, README deliverables |

**Total implementation minutes: 80** (75 task + 5 buffer T06 running in parallel).

---

## Verification Commands (per task)

### T01 — Project scaffold

```
sh
docker compose up -d --wait && docker compose exec app bin/rails runner "puts 'OK'"
```
**Expected:** OK on stdout, exit 0. curl -s http://localhost:3000/ returns non-empty response (Rails welcome page or 404, not connection refused).

---

### T02 — Schema + models

```
sh
docker compose exec app bin/rails db:migrate:status | grep -E 'create_shipments|create_events' | grep up
```
**Expected:** Both migrations show status up. docker compose exec app bin/rails runner "puts Shipment.new(reference:'TV-X').valid?; puts Event.new(event_id:'ev-1',shipment_reference:'TV-X',status:'created',event_timestamp:'2026-07-01T00:00:00Z').valid?" prints true\ntrue.

---

### T03 — POST /api/v1/events

```
sh
# 1. Valid event → 201
curl -s -w '\n%{http_code}' -X POST http://localhost:3000/api/v1/events \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"t3-001","shipment_reference":"TV-T3","status":"created","event_timestamp":"2026-07-01T00:00:00Z"}'
# 2. Duplicate → 200 + duplicate:true
curl -s -w '\n%{http_code}' -X POST http://localhost:3000/api/v1/events \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"t3-001","shipment_reference":"TV-T3","status":"picked_up","event_timestamp":"2026-07-02T00:00:00Z"}'
# 3. Missing field → 422
curl -s -w '\n%{http_code}' -X POST http://localhost:3000/api/v1/events \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"t3-002"}'
# 4. Non-UTC timestamp → 422
curl -s -w '\n%{http_code}' -X POST http://localhost:3000/api/v1/events \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"t3-003","shipment_reference":"TV-T3","status":"created","event_timestamp":"2026-07-01T00:00:00+08:00"}'
# 5. Batch idempotency: same batch twice
BATCH='{"events":[{"event_id":"t3-b1","shipment_reference":"TV-T3B","status":"created","event_timestamp":"2026-07-01T00:00:00Z"},{"event_id":"t3-b2","shipment_reference":"TV-T3B","status":"picked_up","event_timestamp":"2026-07-02T00:00:00Z"},{"event_id":"t3-b1","shipment_reference":"TV-T3B","status":"created","event_timestamp":"2026-07-01T00:00:00Z"}]}'
curl -s -X POST http://localhost:3000/api/v1/events -H 'Content-Type: application/json' -d "$BATCH"
curl -s -X POST http://localhost:3000/api/v1/events -H 'Content-Type: application/json' -d "$BATCH"

```
**Expected:** (1) HTTP 201; (2) HTTP 200, body contains "duplicate":true; (3) HTTP 422; (4) HTTP 422; (5) run 1 `{"accepted":3,"inserted":2,"duplicates":1}`, run 2 `{"accepted":3,"inserted":0,"duplicates":3}`.

---

### T04 — GET /api/v1/shipments

```
sh
# After T03 events exist — query TV-T3 timeline
curl -s http://localhost:3000/api/v1/shipments/TV-T3/timeline | python3 -c "
import sys, json
d = json.load(sys.stdin)
ts = [e['event_timestamp'] for e in d['events']]
assert ts == sorted(ts)
assert d['current_status'] == 'created'
print('PASS: timeline ordered, current_status created')
"
# List all shipments
curl -s http://localhost:3000/api/v1/shipments | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert len(d['shipments']) == 1
assert d['total'] == 1
print('PASS: 1 shipment in list')
"
# Invalid status filter → 400
curl -s -w '\n%{http_code}' 'http://localhost:3000/api/v1/shipments?status=nonexistent'
```
**Expected:** PASS: timeline ordered, PASS: 1 shipment in list, last line HTTP 400.

---

### T05 — Replay tooling

```
sh
# Run 1
docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
# Run 2
docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
```
**Expected Run 1:** stdout contains seed=42 threads=10 shuffled=true, 941 new, 56 duplicates, duplicates=56, 310/310 shipments verified, exit 0.
**Expected Run 2:** stdout contains 0 new events, 0 new, 997 duplicates, duplicates=0, 310/310 shipments verified, exit 0.

---

### T06 — EXPECTED_CMD

```sh
docker compose exec -T app ruby bin/generate_expected.rb
docker compose exec -T app ruby -r json -e 'd=JSON.parse(File.read(".spec/expected_state.json")); raise "shipments" unless d["total_shipments"]==310; raise "events" unless d["total_events"]==941; s=d["status_breakdown"]; raise "breakdown" unless s["delivered"]==97 && s["failed"]==18 && s["in_transit"]==100 && s["picked_up"]==95; puts "PASS: expected_state.json correct"'
```
**Expected:** expected_state.json written: 310 shipments, 941 events, then PASS: expected_state.json correct.

---

### T07 — Test suite

```sh
docker compose exec -T -e RAILS_ENV=test app bundle exec rspec
```
**Expected:** Exit 0. Output includes `8 examples, 0 failures`. No line references `app_development` (test uses `app_test`).

---

### T08 — Test isolation verify

```
sh
# Capture pre-test counts (must be 941 and 310 if SC-10 was run)
docker compose exec db psql -U postgres -d app_development -t -c "SELECT count(*) FROM events" | tr -d ' '
docker compose exec db psql -U postgres -d app_development -t -c "SELECT count(*) FROM shipments" | tr -d ' '
# Run tests (T07)
docker compose exec -T -e RAILS_ENV=test app bundle exec rspec
# Post-test counts must match
docker compose exec db psql -U postgres -d app_development -t -c "SELECT count(*) FROM events" | tr -d ' '
docker compose exec db psql -U postgres -d app_development -t -c "SELECT count(*) FROM shipments" | tr -d ' '
# Re-run replay → 0 new events
docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
```
**Expected:** Pre- and post-test event/shipment counts identical. Replay prints 0 new events, 310/310 shipments verified.

---

### T09 — One-command demo + README

```sh
./bin/demo
```
**Expected:** Exit 0; stdout contains `310/310 shipments verified`.

Manual equivalent:

```
sh
# From clean state
docker compose down -v
docker compose up -d --wait
docker compose exec app bin/rails db:migrate
docker compose exec app ruby bin/generate_expected.rb
docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
```
**Expected:** Exit 0. 310/310 shipments verified. README.md exists with exact above commands in "How to run" section.

---

### T10 — ADR + AI-usage + wrap up

```
sh
test -f ADR.md && echo "ADR: OK"
test -f AI_USAGE.md && echo "AI_USAGE: OK"
test -f README.md && echo "README: OK"
grep -q "docker compose up" README.md && echo "README has startup command"
grep -q "one thing the AI got wrong" AI_USAGE.md && echo "AI-usage has error story"
```
**Expected:** All files exist. README contains startup command. AI_USAGE.md describes at least one AI mistake caught.

---

## SC → Task Coverage Matrix

| SC | Covered by | Verification location |
|----|-----------|----------------------|
| SC-1 | T03 | curl POST valid → 201 |
| SC-2 | T03 | curl POST duplicate → 200 duplicate:true |
| SC-3 | T03 | 3× POST reverse-order → timeline correct |
| SC-4 | T04 | curl GET timeline → events ASC |
| SC-5 | T04 + T06 | curl GET shipments → diff expected_state.json |
| SC-6 | T04 + T06 | curl GET ?status=delivered → 97 |
| SC-7 | T04 | curl GET ?status=nonexistent → 400 |
| SC-8 | T03 | curl POST missing field → 422 |
| SC-9 | T03 | curl POST +08:00 → 422 |
| SC-10 | T05 + T06 | bin/rake replay:full → 310/310 |
| SC-11 | T05 | Run 2 → 0 new events, 310/310 |
| SC-12 | T05 | Run 3 → identical to Run 2 |
| SC-13 | T05 | SEED=12345 → 310/310, states identical |
| SC-14 | T09 | docker compose up + replay → 310/310 |
| SC-15 | T08 | test → counts unchanged → replay 0 new |
| SC-16 | T04 | curl GET timeline on empty DB → 404 (verified before T03 events created) |
| SC-17 | T04 | curl GET shipments on empty DB → total=0 (verified before T03 events created) |
| SC-18 | T03 | batch POST twice → inserted 2 → 0, duplicates 1 → 3 |

**All 17 SCs covered.** No gap.

---

## What I Would Do Next (cut from this timebox)

| # | Feature | Why cut | When to build |
|---|---------|---------|---------------|
| N1 | OpenAPI / Swagger spec generation | ~30 min. Adds machine-readable API docs but spec.md already defines the contract. | Before first external consumer integration. |
| N2 | Multi-seed stress matrix (SEED=1..100, verify all pass) | ~15 min. Adds statistical confidence but SC-13 already covers seed-independence with two seeds. | Before production deployment. |
| N3 | Incremental projection (replay only new events since last run) | ~20 min. Optimises replay for large datasets but 997 rows is trivial. | When CSV exceeds 10,000 rows. |
| N4 | CI pipeline (.github/workflows/test.yml) | ~20 min. Automates T07+T08 but manual verification is sufficient for take-home demo. | Before sharing repo with multiple contributors. |
| N5 | Async processing reference implementation (per ADR design note) | ~60 min. Brief asks for design only, not implementation. ADR in T10 covers the design. | After interview — as a follow-up demonstration. |
| N6 | Pagination on GET /shipments | ~15 min. Spec.md X-11 excludes it; 310 items fits one response. | When shipments exceed 500. |
| N7 | Rate limiting | ~15 min. Not needed for single-user demo replay. | When service is exposed to untrusted networks. |
| N8 | Admin UI / dashboard | ~60 min. API-only service per brief. | After interview, if frontend demo is requested. |

---

> **Gate:** 10 tasks, 80 minutes total (T01–T09 = 65 min implementation + T10 = 15 min docs). All 17 SCs covered. Every task has a single-command verification. Awaiting your review before Phase 4 (Implement).
