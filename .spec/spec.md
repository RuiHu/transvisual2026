# Shipment Events Service — Functional Specification

> Version: 2.0  |  Phase 1 — Specify  |  2026-11-12
> This document describes **what** the system does, **why** each capability matters, and **how to verify success**.
> It describes observable behaviour and verifiable outcomes. Technology names appear only in verification commands and exclusion rationales — never in functional requirements.

---

## 1. User Stories

| # | As a… | I want to… | So that… |
|---|-------|------------|----------|
| US-1 | Carrier system integrator | submit individual shipment tracking events via HTTP | the platform records every step of a shipment''s journey as it happens |
| US-2 | Operations user | retrieve a shipment''s full event timeline with its current status | I can see exactly where any package is and how it got there, regardless of the order events arrived |
| US-3 | Operations user | list all shipments filtered by current status | I can focus on a specific cohort (e.g. all failed deliveries) without scanning everything |
| US-4 | Platform operator | replay a batch of historical events from a CSV file, with duplicates and out-of-order rows deliberately present | I can backfill or audit the system and trust that the final state is always correct |
| US-5 | Platform operator | run the same replay multiple times against the same data | the second and subsequent runs produce zero side effects, proving the system is idempotent end-to-end |

---

## 2. Functional Requirements

### 2.1 Event ingestion

**FR-1 — Accept and record valid event(s)**
When an HTTP POST delivers a well-formed event body with a new `event_id`, the system shall record the event with all four fields (`event_id`, `shipment_reference`, `status`, `event_timestamp`), create the shipment record if the `shipment_reference` is unknown, and respond with HTTP 201 and the recorded event in the response body.

When the same endpoint receives a batch body of the form `{ "events": [ ... ] }`, the system shall apply the per-event rules (FR-2..FR-5) to every element and respond with HTTP 200 and `{ "accepted": N, "inserted": X, "duplicates": Y, "failed": [...] }`. A duplicate `event_id` — whether repeated inside the batch or already stored — counts toward `duplicates` and is never written twice.

**FR-2 — Reject invalid or incomplete event bodies**
When an event body is missing any required field, contains an empty required field, contains a `status` value outside the set {`created`, `picked_up`, `in_transit`, `delivered`, `failed`}, or contains an `event_timestamp` that is not valid ISO 8601 with a `Z` suffix, the system shall respond with HTTP 422 and an error body keyed to the offending field(s), and shall record nothing.

**FR-3 — Reject non-JSON request bodies**
When the request `Content-Type` is not `application/json` or the body is empty or unparseable as JSON, the system shall respond with HTTP 400 and shall record nothing.

### 2.2 Idempotency

**FR-4 — Treat a duplicate event_id as a no-op**
When an event is submitted whose `event_id` has already been recorded, the system shall respond with HTTP 200 and a body containing `"duplicate": true`, and shall not create a second event record, alter the existing event record, or alter any shipment record.

**FR-5 — Survive concurrent duplicate delivery**
When the same `event_id` arrives in two or more concurrent requests, the system shall record exactly one event row for that `event_id`. All requests shall receive a non-5xx response: one 201 and the rest 200 with `"duplicate": true`.

### 2.3 Status derivation rule (the single rule)

**FR-6 — Derive current_status from all recorded events by max timestamp**
While events exist for a shipment, the system shall compute `current_status` as the `status` of the event with the greatest `event_timestamp` among all non-duplicate events for that shipment. This derivation is performed at query time — every timeline or list response reflects the latest state of all recorded events. The system never sets `current_status` from an individual arriving event; it always recomputes from the full event set.

This rule guarantees convergence under any arrival order: after the last event for a shipment has been recorded (regardless of delivery path — sequential, concurrent, or out-of-order), `current_status` is the status of the chronologically latest event. Intermediate queries during ingestion may see transient values, but the final value after all events settle is deterministic and independent of arrival order.

Under N concurrent threads delivering events for the same shipment in arbitrary order, each event insert is atomic and idempotent. After all threads finish, the derivation rule reads all recorded events and selects the max-timestamp status — the result is independent of delivery concurrency, thread scheduling, or arrival order.

**FR-7 — Timestamp tie-break**
When two events for the same shipment share the identical `event_timestamp`, the system shall break the tie using the natural status progression order: `created` < `picked_up` < `in_transit` < `delivered` / `failed` (the latter two are equal — the one with the lexicographically greater `event_id` wins). This edge case does not occur in `carrier_events.csv` but must be defined.

### 2.4 Timeline and query

**FR-8 — Return ordered timeline with current_status**
When a request is made for a shipment''s timeline, the system shall respond with all non-duplicate events ordered by `event_timestamp` ascending (oldest first), plus the shipment''s derived `current_status`. If the `shipment_reference` has no recorded events, the system shall respond with HTTP 404.

**FR-9 — Filter shipment list by current_status**
When a request includes a query parameter `status` whose value is one of the five valid statuses, the system shall respond with a list of all shipments whose derived `current_status` exactly matches that value. Each entry shall include: `shipment_reference`, `current_status`, `event_count`, `latest_event_timestamp`. When no `status` parameter is present, all shipments are returned in one response. The list shall be sorted by `shipment_reference` ascending.

**FR-10 — Reject unknown status filter value**
When a request includes a `status` query parameter whose value is not one of the five valid statuses, the system shall respond with HTTP 400 and an error message, and shall return no shipment data.

### 2.5 Timezone

**FR-11 — Require UTC timestamps**
When an event is submitted, the system shall accept only ISO 8601 timestamps ending with the `Z` suffix (UTC). Timestamps without a timezone indicator, with a non-UTC offset (e.g. `+08:00`), or in any other format shall be rejected with HTTP 422. All internal timestamp comparisons (ordering, max-timestamp derivation) use UTC lexical ordering of the stored strings.

### 2.6 Replay tooling

**FR-12 — Replay CSV events with concurrent delivery**
When the replay command is invoked, the system shall read `carrier_events.csv`, shuffle the rows using a fixed documented random seed, deliver all rows (including 56 duplicate `event_id` rows) via N concurrent HTTP requests to the ingestion endpoint, wait for all deliveries to complete, query the timeline endpoint for every unique shipment, compare each timeline and current_status against the expected-state snapshot derived independently from the CSV (see §5), and report pass/fail.

**FR-13 — Report replay result as a single summary line**
When the replay command finishes, it shall print exactly one summary line containing `X/310 shipments verified` where X is the number of shipments whose timeline and current_status match the expected-state snapshot. Exit code 0 means X = 310.

**FR-14 — Replay idempotency**
When the replay command is run multiple times against the same system instance, the second and subsequent runs shall produce zero new event records, zero shipment state changes, and the same 310/310 verification result as the first run.

---

## 3. Success Criteria

**Every SC references the independent expected-state snapshot (see §5). All expected numbers come from `carrier_events.csv`: 997 rows, 56 duplicate `event_id` rows, 310 unique shipments, 941 unique events. Expected current_status breakdown: 97 delivered + 18 failed + 100 in_transit + 95 picked_up.**

### SC-1 — Single valid event creates shipment and is queryable

- **Depends on:** server running, empty system.
- **Initial state:** zero shipments, zero events.
- **Command:**
  ```sh
  curl -s -w '\n%{http_code}' -X POST $BASE_URL/api/v1/events \
    -H 'Content-Type: application/json' \
    -d '{"event_id":"sc1-001","shipment_reference":"TV-SC1","status":"created","event_timestamp":"2026-07-01T00:00:00Z"}'
  ```
- **Expected:** HTTP 201 on last line. Response body contains `"event_id":"sc1-001"`. Querying `GET /api/v1/shipments/TV-SC1/timeline` returns 1 event, `current_status: "created"`.

### SC-2 — Duplicate event_id returns 200 and creates no second row

- **Depends on:** server running, SC-1 event `sc1-001` already recorded.
- **Initial state:** event `sc1-001` exists for `TV-SC1` (from SC-1).
- **Command:**
  ```sh
  curl -s -w '\n%{http_code}' -X POST $BASE_URL/api/v1/events \
    -H 'Content-Type: application/json' \
    -d '{"event_id":"sc1-001","shipment_reference":"TV-SC1","status":"picked_up","event_timestamp":"2026-07-02T00:00:00Z"}'
  ```
- **Expected:** HTTP 200. Body contains `"duplicate":true`. `GET /api/v1/shipments/TV-SC1/timeline` returns exactly 1 event — unchanged from SC-1.

### SC-3 — Out-of-order ingestion converges to correct timeline

- **Depends on:** server running.
- **Initial state:** empty for `TV-SC3`.
- **Commands (post latest first, earliest last):**
  ```sh
  curl -s -X POST $BASE_URL/api/v1/events -H 'Content-Type: application/json' \
    -d '{"event_id":"sc3-003","shipment_reference":"TV-SC3","status":"delivered","event_timestamp":"2026-07-03T12:00:00Z"}'
  curl -s -X POST $BASE_URL/api/v1/events -H 'Content-Type: application/json' \
    -d '{"event_id":"sc3-002","shipment_reference":"TV-SC3","status":"picked_up","event_timestamp":"2026-07-02T12:00:00Z"}'
  curl -s -X POST $BASE_URL/api/v1/events -H 'Content-Type: application/json' \
    -d '{"event_id":"sc3-001","shipment_reference":"TV-SC3","status":"created","event_timestamp":"2026-07-01T12:00:00Z"}'
  ```
- **Verification command:**
  ```sh
  curl -s $BASE_URL/api/v1/shipments/TV-SC3/timeline | python3 -c "
  import sys, json
  d = json.load(sys.stdin)
  ts = [e['event_timestamp'] for e in d['events']]
  assert ts == sorted(ts), f'FAIL: not sorted: {ts}'
  assert d['current_status'] == 'delivered', f'FAIL: expected delivered, got {d[\"current_status\"]}'
  print('PASS: out-of-order converged to correct timeline')
  "
  ```
- **Expected:** Prints `PASS`. Events ordered `created → picked_up → delivered`. `current_status = "delivered"` (derived from max timestamp, not from ingestion order).

### SC-4 — Timeline returns events in timestamp-ascending order

- **Depends on:** server running, full replay completed.
- **Initial state:** system after one full replay (expected state loaded — §5).
- **Command:**
  ```sh
  curl -s $BASE_URL/api/v1/shipments/TV-200137/timeline | python3 -c "
  import sys, json
  d = json.load(sys.stdin)
  ts = [e['event_timestamp'] for e in d['events']]
  assert ts == sorted(ts), f'FAIL: {ts}'
  print('PASS: TV-200137 events are timestamp-ascending')
  "
  ```
- **Expected:** `PASS`.

### SC-5 — All 310 current_status values match expected-state snapshot

- **Depends on:** server running, full replay completed, `EXPECTED_CMD` has been executed and `.spec/expected_state.json` exists (§5).
- **Initial state:** system after one full replay.
- **Command:**
  ```sh
  curl -s $BASE_URL/api/v1/shipments | python3 -c "
  import sys, json
  actual = json.load(sys.stdin)
  with open('.spec/expected_state.json') as f:
      expected = json.load(f)
  failures = []
  for exp in expected['shipments']:
      ref = exp['shipment_reference']
      act = next((s for s in actual['shipments'] if s['shipment_reference'] == ref), None)
      if act is None:
          failures.append(f'{ref}: missing from API response')
      elif act['current_status'] != exp['current_status']:
          failures.append(f'{ref}: API={act[\"current_status\"]} expected={exp[\"current_status\"]}')
  assert len(failures) == 0, '\n'.join(failures)
  print(f'PASS: {len(actual[\"shipments\"])}/310 current_status values match expected state')
  "
  ```
- **Expected:** `PASS: 310/310 current_status values match expected state`.

### SC-6 — Status filter returns exactly the expected cohort

- **Depends on:** server running, full replay completed, `EXPECTED_CMD` executed and `.spec/expected_state.json` exists.
- **Initial state:** system after one full replay (97 `delivered` in expected state).
- **Command:**
  ```sh
  curl -s "$BASE_URL/api/v1/shipments?status=delivered" | python3 -c "
  import sys, json
  d = json.load(sys.stdin)
  assert all(s['current_status'] == 'delivered' for s in d['shipments']), 'non-delivered shipment in filtered result'
  assert d['total'] == 97, f'expected 97 delivered, got {d[\"total\"]}'
  with open('.spec/expected_state.json') as f:
      expected = [s['shipment_reference'] for s in json.load(f)['shipments'] if s['current_status'] == 'delivered']
  actual_refs = [s['shipment_reference'] for s in d['shipments']]
  assert set(actual_refs) == set(expected), f'mismatch: missing {set(expected)-set(actual_refs)}, extra {set(actual_refs)-set(expected)}'
  print(f'PASS: {d[\"total\"]} delivered shipments, matches expected state')
  "
  ```
- **Expected:** `PASS: 97 delivered shipments, matches expected state`.

### SC-7 — Unknown status filter returns 400

- **Depends on:** server running.
- **Initial state:** any.
- **Command:**
  ```sh
  curl -s -w '\n%{http_code}' "$BASE_URL/api/v1/shipments?status=nonexistent"
  ```
- **Expected:** HTTP 400 on last line. Body contains an error message.

### SC-8 — Missing required field returns 422

- **Depends on:** server running.
- **Initial state:** any.
- **Command:**
  ```sh
  curl -s -w '\n%{http_code}' -X POST $BASE_URL/api/v1/events \
    -H 'Content-Type: application/json' \
    -d '{"event_id":"sc8-001","shipment_reference":"TV-SC8"}'
  ```
- **Expected:** HTTP 422. Body contains error keyed to `status` and/or `event_timestamp`. No event recorded.

### SC-9 — Non-UTC timestamp (with offset) is rejected

- **Depends on:** server running.
- **Initial state:** any.
- **Command:**
  ```sh
  curl -s -w '\n%{http_code}' -X POST $BASE_URL/api/v1/events \
    -H 'Content-Type: application/json' \
    -d '{"event_id":"sc9-001","shipment_reference":"TV-SC9","status":"created","event_timestamp":"2026-07-01T00:00:00+08:00"}'
  ```
- **Expected:** HTTP 422. Body contains error keyed to `event_timestamp`. No event recorded.

### SC-10 — Full replay passes all 310 against expected state

- **Depends on:** server running, `EXPECTED_CMD` executed and `.spec/expected_state.json` exists.
- **Initial state:** empty system (zero shipments, zero events).
- **Command:**
  ```sh
  bin/rake replay:full SEED=42 CONCURRENCY=10
  ```
- **Expected:** Exit code 0. Stdout contains `310/310 shipments verified`. After replay: 310 shipments, 941 events stored (997 delivered − 56 duplicates ignored at ingestion). The `current_status` breakdown matches expected-state snapshot: 97 delivered, 18 failed, 100 in_transit, 95 picked_up.

### SC-11 — Second replay produces zero new rows

- **Depends on:** server running, SC-10 passed.
- **Initial state:** system after one full replay (310 shipments, 941 events).
- **Command:**
  ```sh
  bin/rake replay:full SEED=42 CONCURRENCY=10
  ```
- **Expected:** Exit code 0. Stdout contains `0 new events` and `310/310 shipments verified`. Event count remains 941. Shipment count remains 310.

### SC-12 — Third replay is idempotent (identical to second)

- **Depends on:** server running, SC-11 passed.
- **Initial state:** system after two replays.
- **Command:**
  ```sh
  bin/rake replay:full SEED=42 CONCURRENCY=10
  ```
- **Expected:** Exit code 0. Output identical to SC-11 (`0 new events`, `310/310`). All counts unchanged.

### SC-13 — Different shuffle seed produces identical final state

- **Depends on:** server running, empty system.
- **Initial state:** empty system (fresh, separate from SC-10 run).
- **Command:**
  ```sh
  bin/rake replay:full SEED=12345 CONCURRENCY=10
  ```
- **Expected:** Exit code 0. `310/310 shipments verified`. The set of `(shipment_reference, current_status)` pairs is identical to SC-10's result, and all timelines match the expected-state snapshot (§5).

### SC-14 — One command from clean checkout starts everything and verifies (Constitution Clause 7)

- **Depends on:** host capable of starting containerised services; clean project checkout.
- **Initial state:** project directory freshly cloned; no services running; no database.
- **Command:**
  ```sh
  docker compose up -d --wait && docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
  ```
- **Expected:** Exit code 0. Stdout contains `310/310 shipments verified`. No manual steps between checkout and verification output.
- **Failure-path verification:**
  ```sh
  # Stop the database and try replay — must fail with non-zero exit and readable stderr
  docker compose stop db
  docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10; echo "EXIT=$?"
  ```
- **Expected (failure):** Non-zero exit code. Stderr or stdout contains a human-readable error (e.g. `connection refused`), not a stack trace dump.

### SC-15 — Test suite leaves demo data intact (Constitution Clause 5)

- **Depends on:** server running, full replay completed, test suite exists.
- **Initial state:** system after one full replay (SC-10 passed); 310 shipments, 941 events.
- **Commands:**
  ```sh
  # Record pre-test counts
  docker compose exec db psql -U postgres -d app_development -c "SELECT count(*) FROM events" -t | tr -d ' '
  docker compose exec db psql -U postgres -d app_development -c "SELECT count(*) FROM shipments" -t | tr -d ' '
  # Run test suite (against test database, not development)
  docker compose exec app bin/rails test
  # Re-record development counts
  docker compose exec db psql -U postgres -d app_development -c "SELECT count(*) FROM events" -t | tr -d ' '
  docker compose exec db psql -U postgres -d app_development -c "SELECT count(*) FROM shipments" -t | tr -d ' '
  # Re-run full replay verification
  docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
  ```
- **Expected:** Event count remains 941 and shipment count remains 310 in the development database before and after the test suite. Replay after tests prints `0 new events, 310/310 shipments verified`.

### SC-16 — Unknown shipment returns 404 on empty system (G4 discriminative)

- **Depends on:** server running.
- **Initial state:** empty system (zero shipments, zero events).
- **Command:**
  ```sh
  curl -s -w '\n%{http_code}' $BASE_URL/api/v1/shipments/TV-200001/timeline
  ```
- **Expected:** HTTP 404 on last line. Body contains an error message (e.g. `"Shipment not found"`).
- **Why:** On an empty database, even a shipment reference that exists in the CSV (`TV-200001`) must 404. This SC discriminates an empty-but-running system from a correctly populated one.

### SC-17 — Shipment list returns zero on empty system (G4 discriminative)

- **Depends on:** server running.
- **Initial state:** empty system (zero shipments, zero events).
- **Command:**
  ```sh
  curl -s $BASE_URL/api/v1/shipments | python3 -c "
  import sys, json
  d = json.load(sys.stdin)
  assert d['total'] == 0, f'FAIL: expected total=0, got {d[\"total\"]}'
  assert len(d['shipments']) == 0, f'FAIL: expected empty list, got {len(d[\"shipments\"])} items'
  print('PASS: empty system returns 0 shipments')
  "
  ```
- **Expected:** `PASS: empty system returns 0 shipments`. Response has `total: 0` and an empty `shipments` array.
- **Why:** On an empty database, the shipment list must be empty. This SC discriminatively proves the system does not fabricate data.

### SC-18 — Batch ingestion is idempotent

- **Depends on:** server running.
- **Initial state:** no events for `TV-BATCH` (other shipments may exist).
- **Commands:**
  ```sh
  BATCH='{"events":[
    {"event_id":"batch-1","shipment_reference":"TV-BATCH","status":"created","event_timestamp":"2026-07-01T00:00:00Z"},
    {"event_id":"batch-2","shipment_reference":"TV-BATCH","status":"picked_up","event_timestamp":"2026-07-02T00:00:00Z"},
    {"event_id":"batch-1","shipment_reference":"TV-BATCH","status":"created","event_timestamp":"2026-07-01T00:00:00Z"}]}'
  curl -s -w '\n%{http_code}' -X POST $BASE_URL/api/v1/events -H 'Content-Type: application/json' -d "$BATCH"
  curl -s -w '\n%{http_code}' -X POST $BASE_URL/api/v1/events -H 'Content-Type: application/json' -d "$BATCH"
  ```
- **Expected:** Run 1: HTTP 200 with `"accepted":3,"inserted":2,"duplicates":1`. Run 2: HTTP 200 with `"accepted":3,"inserted":0,"duplicates":3`. Stored rows for `batch-1` + `batch-2` = 2.
- **Why:** Batch delivery must preserve per-event idempotency; a repeated batch inserts nothing new.


---

## 4. SC → Verification Command Map

| SC | What it verifies | Command | Expected output signature | Environment |
|----|------------------|---------|--------------------------|-------------|
| SC-1 | Single event ingestion creates shipment | `curl POST …/events` (new id) → `curl GET …/timeline` | HTTP 201, 1 event, current_status correct | Server running, empty DB |
| SC-2 | Duplicate idempotency | `curl POST …/events` (existing id) | HTTP 200, `"duplicate":true`, 1 row unchanged | Server running, SC-1 done |
| SC-3 | Out-of-order convergence | 3× `curl POST` (reverse order) → `curl GET …/timeline` → python assert | `PASS`, events ASC, current_status=delivered | Server running |
| SC-4 | Timeline timestamp ordering | `curl GET …/timeline` → python assert sorted | `PASS` | Server running, after full replay |
| SC-5 | All 310 statuses vs expected state | `curl GET …/shipments` → python diff vs `.spec/expected_state.json` | `PASS: 310/310` | Server running, after full replay, expected_state.json exists |
| SC-6 | Status filter vs expected state | `curl GET …/shipments?status=delivered` → python diff vs expected_state.json | `PASS: 97 delivered` | Server running, after full replay, expected_state.json exists |
| SC-7 | Invalid filter → 400 | `curl GET …/shipments?status=nonexistent` | HTTP 400 + error body | Server running |
| SC-8 | Missing field → 422 | `curl POST …/events` (missing `status`) | HTTP 422, error body keyed to `status` | Server running |
| SC-9 | Non-UTC timestamp → 422 | `curl POST …/events` (+08:00 timestamp) | HTTP 422, error body keyed to `event_timestamp` | Server running |
| SC-10 | Full replay correctness | `bin/rake replay:full SEED=42 CONCURRENCY=10` | exit 0, `310/310`, 941 events, breakdown matches expected state | Server running, empty DB, expected_state.json |
| SC-11 | Replay run-2 zero-new | `bin/rake replay:full SEED=42 CONCURRENCY=10` (after SC-10) | `0 new events, 310/310`, 941 events unchanged | Server running, SC-10 done |
| SC-12 | Replay run-3 idempotent | `bin/rake replay:full SEED=42 CONCURRENCY=10` (after SC-11) | Identical to SC-11 output | Server running, SC-11 done |
| SC-13 | Seed independence | `bin/rake replay:full SEED=12345 CONCURRENCY=10` (fresh empty DB) | `310/310`, final states identical to SC-10 | Server running, empty DB |
| SC-14 | One-command from clean checkout (Clause 7) | `docker compose up -d --wait && docker compose exec app bin/rake replay:full` | exit 0, `310/310`; failure path: non-zero + readable stderr | Clean checkout , host runs containerised services |
| SC-15 | Test suite preserves demo data (Clause 5) | `bin/rails test` then re-run replay | 0 new events, `310/310`, 941 events, 310 shipments unchanged | Server running, SC-10 done |
| SC-16 | Empty DB → 404 on known shipment (G4) | `curl GET …/TV-200001/timeline` | HTTP 404 | Server running, empty DB |
| SC-17 | Empty DB → 0 shipments (G4) | `curl GET …/shipments` → python assert total=0 | `PASS: empty system returns 0 shipments` | Server running, empty DB |
| SC-18 | Batch idempotency | `curl POST …/events` with `{"events":[...]}` twice | run1 inserted=2 dup=1; run2 inserted=0 dup=3 | Server running |

---

## 5. Expected-State Snapshot (Independent Oracle)

All correctness SCs (SC-5, SC-6, SC-10, SC-11, SC-12, SC-13) diff the system under test against an independent expected state derived **purely from `carrier_events.csv`** — never from the system's own API or database.

### Generation command (`EXPECTED_CMD`)

```sh
docker compose exec -T app ruby bin/generate_expected.rb
```

**This command is an independent oracle.** It reads only `carrier_events.csv` and uses only the Ruby standard library (CSV/JSON). It does **not** require the Rails app and does **not** reuse any code from the system under test — not the ingestion logic, not the status derivation logic, not the API client. It derives expected state purely from the CSV data using the same algorithm described below.

### Derivation algorithm

A script (not the system under test) reads `carrier_events.csv` and produces `.spec/expected_state.json`:

```
For each row in carrier_events.csv:
    Parse (event_id, shipment_reference, status, event_timestamp)
Group by event_id, keep first occurrence  →  941 unique events (56 duplicates discarded)
Group by shipment_reference:
    For each group:
        Sort events by event_timestamp ascending  →  expected timeline order
        current_status = status of event with max(event_timestamp)
        event_count = number of unique events in this group
        latest_event_timestamp = max(event_timestamp)

Output:
{
  "total_shipments": 310,
  "total_events": 941,
  "duplicate_event_ids": 56,
  "status_breakdown": {
    "delivered": 97,
    "failed": 18,
    "in_transit": 100,
    "picked_up": 95
  },
  "shipments": [
    {
      "shipment_reference": "TV-200001",
      "current_status": "delivered",
      "event_count": 3,
      "latest_event_timestamp": "2026-07-05T10:00:00Z",
      "timeline": [
        {"event_id": "...", "status": "created",   "event_timestamp": "2026-07-04T08:00:00Z"},
        {"event_id": "...", "status": "picked_up", "event_timestamp": "2026-07-04T14:00:00Z"},
        {"event_id": "...", "status": "delivered",  "event_timestamp": "2026-07-05T10:00:00Z"}
      ]
    },
    ...
  ]
}
```

### Key expected numbers (from carrier_events.csv)

| Metric | Value | How derived |
|--------|-------|-------------|
| Total CSV rows | 997 | `wc -l carrier_events.csv` minus header |
| Duplicate event_id rows | 56 | Count of `event_id` values appearing ≥ 2 times |
| Unique events stored | **941** | 997 − 56 |
| Unique shipments | **310** | Count of distinct `shipment_reference` values |
| delivered shipments | **97** | Shipments whose max-timestamp event has status `delivered` |
| failed shipments | **18** | Shipments whose max-timestamp event has status `failed` |
| in_transit shipments | **100** | Shipments whose max-timestamp event has status `in_transit` |
| picked_up shipments | **95** | Shipments whose max-timestamp event has status `picked_up` |

### Raw→deduped deltas explained

The raw CSV contains 997 rows. After deduplication by `event_id` (keeping first occurrence, discarding 56 exact-duplicate rows), 941 unique events remain. The status-count deltas between raw and deduped are:

| Status | Raw count | Deduped count | Delta | Cause |
|--------|-----------|---------------|-------|-------|
| `created` | 329 | 310 | −19 | 19 duplicate `event_id` rows removed |
| `picked_up` | 330 | 310 | −20 | 20 duplicate `event_id` rows removed |
| `in_transit` | 219 | 206 | −13 | 13 duplicate `event_id` rows removed |
| `delivered` | 100 | 97 | −3 | 3 duplicate `event_id` rows removed |
| `failed` | 19 | 18 | −1 | 1 duplicate `event_id` row removed |
| **Total** | **997** | **941** | **−56** | 56 unique `event_id` values, each appearing 2× |

**Verification command** (lists the 56 duplicate `event_id` values grouped by status):
```sh
python3 -c "
import csv
from collections import Counter
with open('carrier_events.csv') as f:
    rows = list(csv.DictReader(f))
eid_counts = Counter(r['event_id'] for r in rows)
dups = {eid for eid, c in eid_counts.items() if c > 1}
by_status = Counter(r['status'] for r in rows if r['event_id'] in dups)
print('Duplicate event_id status breakdown:', dict(by_status))
print('Total duplicate event_ids:', len(dups))
print('Total duplicate rows:', sum(by_status.values()))
"
```
**Expected output:** `{created: 19, picked_up: 20, in_transit: 13, delivered: 3, failed: 1}`, total duplicate event_ids = 56, total duplicate rows = 56.

**Key insight:** Every status-count delta between raw CSV and the final deduped system state is caused purely by the 56 duplicate `event_id` rows. There are zero cases of a later (by timestamp) event superseding an earlier event of the same shipment in the source data — when sorted by timestamp and deduped, the event sequence within each shipment always follows the natural progression (created → picked_up → in_transit → delivered/failed) with no regressions.

---

## 6. What We Will NOT Do

| # | Exclusion | Rationale |
|---|-----------|-----------|
| X-1 | Authentication / authorization | Explicitly skipped by the assignment brief |
| X-2 | Webhook signature verification | Not required; carrier trust assumed for demo scope |
| X-3 | Deployment beyond local containerized setup | Deliverable is a local demo |
| X-4 | Multi-tenancy (tenant scoping, isolation) | One flat namespace |
| X-5 | Rate limiting or throttling | Demo scale (~1,000 events) |
| X-6 | Admin UI or dashboard | API-only service |
| X-7 | Status-transition state machine (e.g. rejecting `delivered` before `picked_up`) | **Deliberate choice — documented below.** |
| X-8 | Email / webhook notifications | Not requested |
| X-9 | Event mutation (PATCH / DELETE) | Events are immutable once recorded |
| X-10 | Standalone shipment creation endpoint | Shipments are auto-created on first event ingestion; no `POST /shipments` |
| X-11 | Pagination on the shipment list | 310 items fits in one response; pagination not listed in brief requirements |

### Rationale for X-7: timestamp derivation vs state machine

We deliberately reject a status-transition state machine (which would enforce, e.g., `created` → `picked_up` → `in_transit` → `delivered` and reject out-of-sequence arrivals).

**Why:**

1. **The brief's core requirement is correctness regardless of arrival order.** A state machine would *reject* events arriving out of sequence, which contradicts the brief. The system must accept all events and derive the correct state afterward.
2. **Carriers send data asynchronously.** A `picked_up` scan may arrive after a `delivered` scan due to batch uploads, device sync delays, or network partitions. The system should not punish the carrier for infrastructure timing.
3. **The correct state is the chronologically latest event the carrier reported.** Whether a `failed` at 10:00 is superseded by a `delivered` at 11:00 (package recovered) or vice versa (delivery attempt failed after initial success signal), the system trusts the carrier's latest word.
4. **Simplicity.** A state machine requires transition tables, validation logic, and error recovery paths for out-of-order arrivals — all of which are unnecessary when the derivation rule is "latest timestamp wins." This keeps the ingestion path stateless with respect to prior events.

This choice will be defended in the ADR (Phase 7).

---

## 7. Assumptions & Open Questions

Open questions that the spec does **not** answer — these need your decision before implementation.

| # | Topic | Question | Impact if unresolved |
|---|-------|----------|---------------------|
| Q-1 | **Duplicate event_id scope** | ~~Open.~~ **Resolved.** `event_id` is globally unique. The CSV data confirms this: 56 duplicate `event_id` values exist, and each appears within a single `shipment_reference` — none span multiple shipments. Idempotency key = `event_id` alone. | N/A (decided in spec) |
| Q-2 | **Replay concurrency model** | Threads within one process vs. multiple processes vs. async HTTP client? Spec only says "N concurrent requests." | Affects replay tooling implementation and resource usage. |
| Q-3 | **API-only scaffolding expectation** | Brief says "API mode is fine." Does the reviewer expect an explicit API-only project scaffolding, or is a standard setup with unused middleware stripped acceptable? | Affects project generation command in Phase 2. |

### Questions resolved in the spec (not open)

These were considered and decided within the functional requirements above — no further input needed:

| Topic | Decision | Where |
|-------|----------|-------|
| Unknown status filter → 400 or 200 empty? | 400 with error message | FR-10 |
| Error response format | `{"errors": {"field": ["message"]}}` | FR-2 |
| Non-JSON Content-Type → 400 or 415? | 400 | FR-3 |
| Accept `+00:00` offset timestamps? | No — `Z` suffix only, matching CSV format | FR-11 |
| Fractional seconds in timestamps? | Not accepted (not in CSV data) | FR-11 |
| Shipment list sort order (unfiltered) | `shipment_reference` ascending | FR-9 |
| Pagination? | No — 310 items in one response | X-11 |

---

## 8. Verification Bindings

### 8.1 Constitution → SC Mapping

Each MUST clause from `.spec/constitution.md` (v1.0, 9 clauses) maps to specific SCs with concrete verification commands:

| Clause | SC | Verification command |
|--------|----|----------------------|
| 1 — Machine-verifiable acceptance criteria | All SCs | `rg -n "good performance|clean code|elegant|robust|should be|ought to" .spec/spec.md` → zero matches in SC sections |
| 2 — Runtime verification only | All SCs | Every SC command invokes `curl` or `bin/rake` against a live server; none are static file references |
| 3 — Full correctness replay | SC-10, SC-11, SC-12, SC-13 | `bin/rake replay:full SEED=42 CONCURRENCY=10` (empty DB, 2 runs, zero new on run 2) |
| 4 — Demo / test data isolation | SC-15 | `bin/rails test` then re-run replay → 0 new events, counts unchanged |
| 5 — README runtime honesty | SC-15 | Test suite + replay-after-tests exercises the documented runtime end-to-end |
| 6 — One-command demo | SC-14 | `docker compose up -d --wait && docker compose exec app bin/rake replay:full` from clean checkout |
| 7 — No unrequired dependencies | SC-14 | The one-command demo stack contains only the the application service + the database service; no additional services |
| 8 — Replay idempotency | SC-11, SC-12 | `bin/rake replay:full` runs 2 and 3 → 0 new events, identical output |
| 9 — Constitution self-policing | This table | **Command:** `rg -c "^### \d" .spec/constitution.md` → 9; `rg -c "\*\*Verification\*\*" .spec/constitution.md` → ≥ 9; both must match → PASS |
### 8.2 SC Execution Environment

| SC | Requires server? | Requires DB state | Prerequisite commands | External dependency |
|----|-----------------|-------------------|----------------------|---------------------|
| SC-1 | Yes | Empty | Server start | `curl` |
| SC-2 | Yes | SC-1 executed | SC-1 | `curl` |
| SC-3 | Yes | Empty for TV-SC3 | Server start | `curl`, `python3` |
| SC-4 | Yes | Full replay done | SC-10 | `curl`, `python3` |
| SC-5 | Yes | Full replay done | SC-10, `.spec/expected_state.json` exists | `curl`, `python3` |
| SC-6 | Yes | Full replay done | SC-10, `.spec/expected_state.json` exists | `curl`, `python3` |
| SC-7 | Yes | Any | Server start | `curl` |
| SC-8 | Yes | Any | Server start | `curl` |
| SC-9 | Yes | Any | Server start | `curl` |
| SC-10 | Yes | Empty | Server start, DB reset, `.spec/expected_state.json` exists | `curl` (replay tooling uses it internally) |
| SC-11 | Yes | SC-10 done | SC-10 | Replay tooling |
| SC-14 | Yes | Empty (clean checkout) | `docker compose up -d --wait` | `docker`, `docker compose` |
| SC-15 | Yes | SC-10 done | SC-10, test suite exists | Replay tooling, test framework |
| SC-16 | Yes | Empty | Server start | `curl` |
| SC-17 | Yes | Empty | Server start | `curl`, `python3` |
| SC-18 | Yes | Any | Server start | `curl` |

### 8.3 SC Dependency Graph

```
SC-1 ──→ SC-2
SC-3 (independent)
SC-10 ──→ SC-11 ──→ SC-12
SC-10 ──→ SC-4, SC-5, SC-6
SC-13 (independent, needs fresh DB)
SC-14 (independent — from clean checkout, includes SC-10 path)
SC-15 (depends on SC-10 + test suite)
SC-16, SC-17 (independent — from empty DB, must run BEFORE SC-10)
SC-18 (independent — batch ingestion)
SC-7, SC-8, SC-9 (independent, can run any time)
```

---

### 8.4 Tool availability in target runtime

| Tool | Required by SC(s) | Available in target runtime? |
|------|-------------------|------------------------------|
| `curl` | SC-1–SC-9 | Yes — available in the target runtime environment |
| `python3` | SC-3–SC-6, EXPECTED_CMD | Yes — available in the target runtime environment; also available on host |
| `docker` | SC-14, SC-15 | Yes — Docker version 29.9.3 (see `.spec/env.md`) |
| `docker compose` | SC-14, SC-15 | Yes — Docker Compose version v5.7.0 (see `.spec/env.md`) |
| `bin/rake` | SC-10–SC-15 | In-app — available inside the application service |
| `bin/rails` | SC-15 | In-app — available inside the application service |
| `psql` | SC-15 | In-container — run inside the database service |
| SC-12 | Yes | SC-11 done | SC-11 | Replay tooling |
| SC-13 | Yes | Empty (fresh reset) | DB reset, `.spec/expected_state.json` exists | Replay tooling |

> **Gate:** All 18 SCs reference the independent expected-state snapshot (§5). SC-10 starts from empty system. Every SC has a concrete verification command and declared execution environment. Awaiting your review.
