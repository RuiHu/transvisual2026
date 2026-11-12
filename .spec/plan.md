# Shipment Events Service — Implementation Plan

> Version: 1.0  |  Phase 2 — Plan  |  2026-11-12
> This document answers **how** to build. It names technologies, data types, and interface signatures.
> Every design decision traces to a spec.md FR / SC.

---

## 1. Architecture Overview

```
carrier_events.csv
       │
       ▼
┌─────────────────────────────────┐
│  Replay Tooling (rake task)     │
│  Ruby stdlib: CSV, Net::HTTP    │
│  Thread.new × CONCURRENCY       │
│  Array#shuffle(random: seed)    │
└──────────────┬──────────────────┘
               │ POST /api/v1/events  (JSON)
               ▼
┌─────────────────────────────────┐
│  Rails API (--api mode)         │
│  port 3000                      │
│                                 │
│  EventsController#create        │
│  ShipmentsController#index      │
│  ShipmentsController#show       │
└──────────────┬──────────────────┘
               │ ActiveRecord
               ▼
┌─────────────────────────────────┐
│  PostgreSQL (Docker Compose)    │
│  database: app_development      │
│  tables: shipments, events      │
└─────────────────────────────────┘
```

### One-event write call chain (POST /api/v1/events)

```
1. HTTP POST  →  Rails router  →  EventsController#create
2. Strong params: permit(event_id, shipment_reference, status, event_timestamp)
3. Validate: event_id present?, status in VALID_STATUSES, timestamp matches ISO8601+Z
   ── invalid → 422 + {errors: {field: ["message"]}}
4. BEGIN transaction
5.   shipment = Shipment.find_or_create_by!(reference: params[:shipment_reference])
6.   event = shipment.events.create!(permitted_params)
7.   ── PG::UniqueViolation on events.event_id →
8.        ROLLBACK, return 200 + {..., duplicate: true}
9. COMMIT
10. Return 201 + event JSON
```

**Trace:** FR-1 (record event + create shipment), FR-2 (validate), FR-3 (reject malformed), FR-4 (idempotent by event_id), FR-6 (shipment auto-created).

### current_status derivation (query-time, not persisted)

```ruby
# Shipment model — computed, never stored
def current_status
  events.order(event_timestamp: :desc, event_id: :desc).pick(:status)
end
```

**Why not a persisted column:** A cached `current_status` on `shipments` creates a write–write race under concurrent ingestion (two events for the same shipment in parallel transactions — the last committer overwrites with a potentially stale status). A computed derivation reads the committed event set at query time and is always correct (FR-6 convergence guarantee).

**Cost:** Shipment list filtered by status must load all events and filter in Ruby (N+1 avoided via `includes(:events)`). At 310 shipments (~941 events), this is ~5 ms — acceptable for demo scale. See Trade-off Table #1.

**Trace:** FR-6, FR-9, SC-5.

---

## 2. Data Model DDL

### 2.1 shipments

```sql
CREATE TABLE shipments (
    id            BIGSERIAL PRIMARY KEY,
    reference     VARCHAR(50)  NOT NULL,
    created_at    TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_shipments_reference ON shipments (reference);
```

| Column | Type | Rationale |
|--------|------|-----------|
| `id` | BIGSERIAL PK | Standard Rails PK. Tiny table (310 rows), BIGSERIAL is the Rails default. |
| `reference` | VARCHAR(50) | Natural key from carrier (e.g. `TV-200070`). 50 chars is generous headroom. NOT NULL — every shipment has a reference. |
| `created_at` / `updated_at` | TIMESTAMP | Rails timestamps. `updated_at` is touched on find-or-create but is not a correctness signal (current_status is derived, not cached). |

**Index — `idx_shipments_reference` (UNIQUE):**
- Serves: `find_or_create_by!(reference:)` on every event POST (FR-1, SC-1). Without this index, every ingestion does a sequential scan on 310 rows.
- Why UNIQUE: prevents duplicate shipment rows under concurrent find-or-create (FR-5 concurrency safety).

### 2.2 events

```sql
CREATE TABLE events (
    id                  BIGSERIAL    PRIMARY KEY,
    event_id            VARCHAR(50)  NOT NULL,
    shipment_reference  VARCHAR(50)  NOT NULL,
    status              VARCHAR(20)  NOT NULL,
    event_timestamp     VARCHAR(25)  NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_events_event_id ON events (event_id);
CREATE INDEX idx_events_ship_ts ON events (shipment_reference, event_timestamp);
```

| Column | Type | Rationale |
|--------|------|-----------|
| `id` | BIGSERIAL PK | Standard. 941 rows. |
| `event_id` | VARCHAR(50) | UUID from carrier. Stored as string — no native UUID type dependency. 50 chars covers standard UUID length. UNIQUE constraint = idempotency enforcement (FR-4). |
| `shipment_reference` | VARCHAR(50) | Joins to `shipments.reference`. No FK constraint — string reference is sufficient for demo scale (X-2: no webhook signatures, so no cascading integrity needed). |
| `status` | VARCHAR(20) | One of 5 values. VARCHAR is simpler than ENUM; Rails validates at app layer (FR-2). |
| `event_timestamp` | VARCHAR(25) | ISO 8601 string with Z suffix. Stored as-is; UTC lexical ordering works because all timestamps share the same format and timezone (FR-11). A `timestamptz` type would add parsing complexity without benefit — the CSV provides strings, the API returns strings, no arithmetic is performed. |

**Index 1 — `idx_events_event_id` (UNIQUE):**
- Serves: idempotency check on every POST (FR-4, SC-2, SC-11). This is the most hit index — every single event delivery checks it.
- UNIQUE: the database-level enforcement that makes concurrent-duplicate safety possible (FR-5, SC-5 under concurrency).

**Model association:** `Shipment has_many :events, foreign_key: :shipment_reference`. The `shipment_reference` string on `events` joins to `shipments.reference` without an integer FK column (Trade-off #2: string reference, no FK constraint).

**Index 2 — `idx_events_ship_ts` (composite on `shipment_reference`, `event_timestamp`):**
- Serves: timeline query `SELECT * FROM events WHERE shipment_reference = ? ORDER BY event_timestamp` (FR-8, SC-4).
- Serves: current_status derivation `... ORDER BY event_timestamp DESC LIMIT 1` (FR-6, SC-5).
- Composite order: `shipment_reference` first (equality filter), `event_timestamp` second (sort). The index covers both without a second index on `event_timestamp` alone, which would never be queried without `shipment_reference`.

**Why exactly 3 indexes (no more):**

| Candidate index | Why not built |
|-----------------|---------------|
| `events(status)` | Status queries go through `shipments` + derived `current_status`, never directly on `events.status`. |
| `shipments(current_status)` | `current_status` is not a persisted column. Even if it were, 310 rows → sequential scan ~1 ms. Index maintenance cost > query benefit. |
| `events(event_timestamp)` alone | Timeline queries always include `shipment_reference`. The composite index covers both. |
| `events(created_at)` | No query filters or sorts by ingestion time. |

**Trace:** All FRs touching data: FR-1, FR-4, FR-5, FR-6, FR-8, FR-9, FR-11, SC-1 through SC-13.

---

## 3. Transaction & Concurrency Strategy

### 3.1 What is in one transaction (POST /api/v1/events)

```
BEGIN
  shipment = Shipment.find_or_create_by!(reference: ref)   -- (1)
  event = Event.create!(event_id: eid, ...)                 -- (2)
COMMIT
```

Both (1) and (2) share one transaction to prevent a partial state: shipment created but event insertion fails → shipment would be an orphan. On rollback, the shipment create is also undone if it was new.

**Trace:** FR-1 (atomic event+shipment creation).

### 3.2 Problem A — Same event_id duplicated (FR-4, FR-5)

**Threat:** Two concurrent POSTs with the same `event_id`.

**Defense chain:**
1. Both transactions attempt `INSERT INTO events (event_id, ...) VALUES ('dup-01', ...)`.
2. The UNIQUE constraint on `events.event_id` serialises them at the database level.
3. First transaction: INSERT succeeds, COMMIT → 201.
4. Second transaction: INSERT raises `PG::UniqueViolation`. ActiveRecord translates to `ActiveRecord::RecordNotUnique`.
5. Application rescues `RecordNotUnique`, queries the existing row, returns 200 with `{..., duplicate: true}`.

```ruby
def create
  shipment = Shipment.find_or_create_by!(reference: event_params[:shipment_reference])
  event = shipment.events.create!(event_params)
  render json: event, status: :created
rescue ActiveRecord::RecordNotUnique
  existing = Event.find_by!(event_id: event_params[:event_id])
  render json: existing.as_json.merge(duplicate: true), status: :ok
end
```

**Why not `find_or_create_by!` for events:** `find_or_create_by!` is not concurrency-safe — two threads can both pass the `find` step (returning nil) and both attempt `create`, one failing. `create!`-with-rescue is race-free given the UNIQUE constraint.

**Trace:** FR-4 (duplicate → 200), FR-5 (concurrent duplicates → exactly one row).

### 3.3 Problem B — Two different events for the same shipment concurrently (FR-6)

**Threat:** Thread A posts event for TV-001 with timestamp 10:00 (status `picked_up`). Thread B posts event for TV-001 with timestamp 11:00 (status `delivered`). Both arrive concurrently.

**Why this is safe:**
- Both have different `event_id` values → no UNIQUE violation.
- Both INSERTs succeed (in any order, any timing).
- Shipment `find_or_create_by!` is safe: first thread creates the shipment row, second thread finds it (UNIQUE on `reference` prevents duplicate shipment creation).
- `current_status` is **not persisted**. After both transactions commit, any query reads all events for TV-001, finds max timestamp (11:00, `delivered`), and returns `delivered`. This is correct regardless of which INSERT committed first.

**No cache-invalidation problem:** There is no cached `current_status` to invalidate. The derivation is always fresh.

**Trace:** FR-6 (status derived from all events, converges regardless of concurrency), FR-7 (timestamp-based derivation).

---

## 4. API Contract (implementation detail)

### 4.1 POST /api/v1/events

```
Path:    POST /api/v1/events
Controller: EventsController#create
Params:  { event_id: String, shipment_reference: String, status: String, event_timestamp: String }
         or { events: [ {event_id:, shipment_reference:, status:, event_timestamp:}, ... ] }
```

**Validation rules:**
- `event_id`: required, non-blank
- `shipment_reference`: required, non-blank
- `status`: required, inclusion in `%w[created picked_up in_transit delivered failed]`
- `event_timestamp`: required, format `/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/`

**Responses:**

| Code | Condition | Body |
|------|-----------|------|
| 201 | New event created | `{ event_id:, shipment_reference:, status:, event_timestamp: }` |
| 200 | Duplicate event_id | Same as above + `"duplicate": true` |
| 200 | Batch body `{"events":[...]}` | `{ accepted:, inserted:, duplicates:, failed: [] }` — per-event idempotency applied to every element |
| 422 | Validation failure | `{ errors: { field: ["message"] } }` |
| 400 | Malformed JSON | `{ error: "Bad request" }` — handled by Rails `rescue_from ActionDispatch::Http::Parameters::ParseError` |

**Why 200, not 409, for duplicates:** 409 Conflict means "the request conflicts with the current state of the resource and the client should resolve the conflict and retry." An idempotent re-POST has no conflict to resolve — the desired state already exists. 200 OK with a `duplicate` flag is the standard idempotency-receipt pattern (used by Stripe, GitHub, etc.). Returning 409 would incorrectly signal that the client made an error.

**Trace:** FR-1 (201 single / 200 batch), FR-2 (422), FR-3 (400), FR-4 (200 + duplicate:true), SC-18 (batch idempotency).

### 4.2 GET /api/v1/shipments/:reference/timeline

```
Path:    GET /api/v1/shipments/:reference/timeline
Controller: ShipmentsController#show  (or #timeline)
Params:  :reference — URL segment, e.g. TV-200070
```

**Responses:**

| Code | Condition | Body |
|------|-----------|------|
| 200 | Shipment exists | `{ shipment_reference:, current_status:, events: [{ event_id:, status:, event_timestamp: }, ...] }` — events ordered by event_timestamp ASC |
| 404 | Shipment not found | `{ error: "Shipment not found" }` |

**Implementation:**
```ruby
def timeline
  shipment = Shipment.find_by!(reference: params[:reference])
  events = shipment.events.order(event_timestamp: :asc)
  render json: {
    shipment_reference: shipment.reference,
    current_status: shipment.current_status,  # derived, see §3
    events: events.as_json(only: [:event_id, :status, :event_timestamp])
  }
end
```

**Trace:** FR-8 (ordered events + current_status), SC-4, SC-5.

### 4.3 GET /api/v1/shipments

```
Path:    GET /api/v1/shipments
Params:  ?status=<status>  (optional, one of five valid values)
Controller: ShipmentsController#index
```

**Responses:**

| Code | Condition | Body |
|------|-----------|------|
| 200 | (with or without filter) | `{ shipments: [{ shipment_reference:, current_status:, event_count:, latest_event_timestamp: }, ...], total: N }` — sorted by shipment_reference ASC |
| 400 | Invalid status value | `{ error: "Invalid status filter" }` |

**Implementation:**
```ruby
def index
  shipments = Shipment.includes(:events).order(:reference)
  if params[:status].present?
    unless Event::VALID_STATUSES.include?(params[:status])
      return render json: { error: "Invalid status filter" }, status: :bad_request
    end
    shipments = shipments.select { |s| s.current_status == params[:status] }
  end
  render json: {
    shipments: shipments.map { |s|
      latest = s.events.max_by { |e| [e.event_timestamp, e.event_id] }
      {
        shipment_reference: s.reference,
        current_status: s.current_status,
        event_count: s.events.size,
        latest_event_timestamp: latest&.event_timestamp
      }
    },
    total: shipments.size
  }
end
```

**Note on `includes(:events)`:** At 310 shipments, loading all events into memory (~941 rows × ~4 fields) is negligible (~50 KB). The Ruby `select` avoids a complex SQL subquery for status filtering. See Trade-off Table #3.

**Trace:** FR-9 (list filtered by status, sorted by reference), FR-10 (invalid status → 400), SC-6, SC-7, SC-16, SC-17.

---

## 5. Replay & Verification Design

### 5.1 Replay tooling (rake task)

```
Entry point:  bin/rake replay:full  (lib/tasks/replay.rake)
Accepts:      ENV["SEED"] (default 42), ENV["CONCURRENCY"] (default 10), ENV["BASE_URL"] (default http://localhost:3000)
```

**Algorithm:**

```
1. Load CSV:   rows = CSV.read("carrier_events.csv", headers: true).map(&:to_h)
2. Shuffle:    rows.shuffle!(random: Random.new(SEED))
3. Queue:      queue = Queue.new; rows.each { |r| queue << r }
4. Spawn N threads:
     each thread:
       loop:
         row = queue.pop(true) rescue break
         POST BASE_URL + "/api/v1/events" with JSON body
         record response code (201 = new, 200 = duplicate)
5. Wait:       threads.each(&:join)
6. Report:     puts "seed=#{SEED} threads=#{CONCURRENCY} shuffled=true"
               puts "#{new_count} new, #{dup_count} duplicates"; puts "duplicates=#{dup_count}"
               puts "0 new events" if new_count == 0
7. Verify:     load .spec/expected_state.json; failures = 0
               for each of 310 shipments:
                 GET BASE_URL + "/api/v1/shipments/#{ref}/timeline"
                 diff timeline and current_status against expected
               failures = 0
               for each of 310 shipments:
                 GET BASE_URL + "/api/v1/shipments/#{ref}/timeline"
                 diff timeline and current_status against expected
                 if mismatch: failures += 1; print diff
               verified = 310 - failures
               puts "#{verified}/310 shipments verified"
8. Exit:       exit(failures == 0 ? 0 : 1)
```

**Random seed:** `Random.new(42)` is the Ruby stdlib PRNG (Mersenne Twister). `Array#shuffle(random: rng)` guarantees identical shuffle order for the same seed across runs.

**Thread safety:** Each thread does independent HTTP POSTs. The `Queue#pop(true)` (non-blocking) pattern drains the queue without locking. No shared mutable state beyond the atomic new/dup counters.

**Trace:** FR-12 (shuffle + concurrent delivery + verification), FR-13 (summary line), FR-14 (second run idempotent), SC-10 through SC-14.

### 5.2 Two-pass verification

```
Run 1 (empty DB):
  $ bin/rake replay:full SEED=42 CONCURRENCY=10
  → seed=42 threads=10 shuffled=true
  → duplicates=56
  → 941 new, 56 duplicates
  → 310/310 shipments verified

Run 2 (same DB):
  $ bin/rake replay:full SEED=42 CONCURRENCY=10
  → seed=42 threads=10 shuffled=true
  → 0 new events
  → duplicates=0
  → 0 new, 997 duplicates
  → 310/310 shipments verified

Run 3:
  → seed=42 threads=10 shuffled=true
  → 0 new events
  → duplicates=0
  → 0 new, 997 duplicates
  → 310/310 shipments verified (identical to Run 2)
```

The replay tool does NOT reset the database. Run 1 expects empty DB (precondition). Runs 2 and 3 prove idempotency.

**Trace:** SC-10, SC-11, SC-12.

### 5.3 Independent oracle (EXPECTED_CMD)

The replay tool does **not** generate expected values. It only compares API output against `.spec/expected_state.json`, which is produced by a **separate** Ruby script (`EXPECTED_CMD` in spec.md §5). This script reads only `carrier_events.csv`, uses only the Ruby stdlib (CSV/JSON), and shares zero code paths with the Rails app.

**Verification that the oracle is independent:**
```sh
# EXPECTED_CMD runs on the host, not in Docker
docker compose exec -T app ruby bin/generate_expected.rb   # see spec.md §5
# The Rails app never executes this code.
# The replay tooling only loads the .json file.
```

**Trace:** SC-5, SC-10 (oracle independence).

---

## 6. Trade-off Table

| # | Decision | Option A | Option B | Chosen | Rationale | Cost | Reconsider if |
|---|----------|----------|----------|--------|-----------|------|---------------|
| 1 | `current_status` storage | Persisted column on shipments, updated per insert | Derived at query time from events | **B: derived** | No write–write race under concurrency. Always correct regardless of commit order (FR-6 convergence). | Status-filtered list loads all events in memory (941 rows, ~50 KB) — acceptable at demo scale. | Shipment count exceeds 10,000 OR status-filter query latency exceeds 200 ms. |
| 2 | Event–shipment relationship | `belongs_to :shipment` via `shipment_id` FK | String `shipment_reference`, no FK | **B: string reference** | Simplest mapping to CSV data. No join table or FK cascade needed. | No referential integrity at DB level — acceptable for demo (no deletes). | Multi-tenancy or shipment deletion is required — then FK + cascades become necessary. |
| 3 | Status-filter implementation | SQL subquery with lateral join or window function | Ruby `select` after `includes(:events)` | **B: Ruby filter** | Avoids complex SQL. Readable, testable. At 310 shipments, runtime ~5 ms. | N+1-free via `includes`. Memory: ~941 event objects. | Shipment count exceeds 5,000 — switch to SQL with indexed subquery. |
| 4 | Index on `shipments.current_status` | Add composite index `(current_status, reference)` | No index — sequential scan | **B: no index** | `current_status` is not persisted (decision #1). Even if it were, 310 rows → seq scan ~1 ms. | No measurable impact at demo scale. | Shipment count exceeds 5,000 AND `current_status` becomes persisted. |
| 5 | Replay concurrency model | `Process.fork` + `Process.waitall` | `Thread.new` + `Queue` | **B: threads** | I/O-bound workload (HTTP POSTs). Ruby threads yield on I/O, achieving effective concurrency without process overhead. Zero additional gems. | GIL prevents true CPU parallelism — irrelevant for HTTP I/O. Thread count capped at ~10 for stability. | Replay exceeds 10,000 events OR thread contention measured — switch to forked processes or async HTTP (e.g., Typhoeus). |
| 6 | Duplicate detection strategy | `Event.find_or_create_by!(event_id:)` | `Event.create!` + rescue `RecordNotUnique` | **B: insert-then-rescue** | `find_or_create_by!` has a TOCTOU race: two threads both `find` (nil), both `create`, one fails. `create!`-with-rescue uses the DB UNIQUE constraint as the atomic arbiter — race-free. | Slightly less idiomatic Rails code. One extra rescue branch. | ActiveRecord provides a native atomic upsert (e.g., `insert_all` with `unique_by`) in a future version. |
| 7 | Timestamp format acceptance | Only `Z` suffix (UTC) | `Z` or `+00:00` offset | **A: Z only** | CSV data uses Z exclusively. Accepting `+00:00` adds regex complexity for zero benefit. FR-11: reject non-UTC. | Non-Z UTC timestamps (e.g., `+00:00`) are rejected → 422. Carrier must normalise. | Carrier partners require `+00:00` or fractional seconds — add format support with clear validation. |
| 8 | Rails generation mode | `rails new --api` (API-only) | `rails new` + manual middleware removal | **A: --api** | Brief says "Rails API mode is fine." Lighter middleware stack, no view layer, smaller memory footprint. | Slightly less familiar to developers used to full Rails. No asset pipeline, no cookies/sessions (not needed). | Requirements add browser-facing features (HTML views, sessions, CSRF). |
| 9 | Error response format | RFC 7807 Problem Details (`type`, `title`, `status`, `detail`) | Simple `{ errors: { field: ["msg"] } }` | **B: simple hash** | Easier to consume in curl scripts and replay tooling. Less code. Spec.md FR-2 defines this format. | Not standards-compliant for public APIs. Not machine-readable by generic error parsers. | Service becomes a public API consumed by third-party systems — migrate to RFC 7807. |
| 10 | Pagination | Included (page/per_page params) | Excluded (all results in one response) | **B: excluded** | Brief says "skip anything not listed." 310 shipments fit one response. Spec.md X-11 covers this. | Large response body (~50 KB for full list). No degradation at demo scale. | Shipment count exceeds 500 — add pagination with `page` and `per_page` params, default per_page=50. |
| 11 | Database provisioning | Docker Compose PostgreSQL service | Local PostgreSQL install | **A: Docker Compose** | `psql` is not installed locally (`.spec/env.md`). Docker is available (v29.9.3). One-command demo (SC-14) requires containerised stack. | Docker daemon must be running. Cold start ~3 seconds for PG container. | Reviewer requires local PG (no Docker). Add `database.yml` env-var switching. |
| 12 | CSV parsing in replay | `CSV.read` (Ruby stdlib) | Manual line splitting | **A: CSV stdlib** | Handles quoting, escaping, header mapping. Zero additional gems. Built into Ruby. | ~5 ms for 997 rows. No streaming needed at this scale. | CSV exceeds 100,000 rows — switch to `CSV.foreach` for streaming. |

**Trace:** Every trade-off maps to FR and SC via the rationale column. Specific traces: #1→FR-6,SC-5; #2→FR-1; #3→FR-9,SC-6,SC-17; #4→FR-9; #5→FR-12,SC-10; #6→FR-4,FR-5,SC-2; #7→FR-11,SC-9; #8→FR-1,SC-14; #9→FR-2; #10→X-11; #11→SC-14; #12→FR-12.
---

## 7. Risk Register

| # | Risk | Likelihood | Impact | Trigger signal | Mitigation | Trace |
|---|------|------------|--------|----------------|------------|-------|
| R1 | **PostgreSQL unreachable** — Docker daemon not running or port 5432 occupied | Medium | High — entire demo blocked | `docker compose up` fails with "port is already allocated" or "Cannot connect to the Docker daemon" | `docker compose ps` to check status; `docker compose down -v && docker compose up -d` to reset; document port conflict resolution in README. | SC-14 (one-command demo) |
| R2 | **CSV file missing or malformed** — `carrier_events.csv` absent, encoding issue, or BOM prefix on Windows | Low | High — replay tool exits with parse error | `bin/rake replay:full` raises `Errno::ENOENT` or `CSV::MalformedCSVError` | Replay tool validates `File.exist?("carrier_events.csv")` before parsing, prints "carrier_events.csv not found in project root" and exits 1. Add BOM handling (`csv.read` with `encoding: 'bom|utf-8'`). | FR-12, SC-10 |
| R3 | **Concurrent replay overwhelms server** — 10 threads × 997 POSTs saturates Puma's connection pool, returns 5xx | Low | Medium — verification fails with fewer than 310/310 | Replay output shows non-201/non-200 response codes | Reduce `CONCURRENCY` env var (default 10 → 5). Retry failed POSTs once (idempotent, safe). Document `CONCURRENCY` tuning in README. | FR-12, SC-10 |
| R4 | **expected_state.json out of date** — CSV changes but expected_state.json was not regenerated | Low | Medium — replay verification fails with legitimate data | Replay reports fewer than 310/310 verified, but the data is actually correct | Replay tool's verify step reads `expected_state.json` and reports mismatch details. README documents `EXPECTED_CMD` as prerequisite. CI/script can regenerate automatically before replay. | SC-5, SC-10 |
| R5 | **Timestamp format mismatch** — CSV has Z-suffix timestamps but a carrier sends a different ISO 8601 variant during manual testing | Low | Low — single events rejected with 422 | `curl` POST returns 422 with error keyed to `event_timestamp` | Validation message is self-documenting ("must be ISO 8601 with Z suffix"). No silent failures. | FR-11, SC-9 |
| R6 | **Thread exhaustion during replay** — Ruby thread scheduler deadlocks or queue contention stalls the replay | Very Low | Medium — replay hangs | Replay produces no output for >30 seconds | Replay prints progress every 100 events ("delivered 100/997..."). Timeout: if no progress for 30 seconds, print "replay stalled" and exit 1. | FR-12, SC-10 |
| R7 | **Database in wrong state before replay** — Run 1 expects empty DB but previous data exists | Medium | Medium — replay reports incorrect counts (e.g., "900 new" instead of "941 new") | Run 1 new-event count ≠ 941 | Replay prints pre-existing row counts before starting: "DB state: X shipments, Y events". README documents prerequisite: `docker compose down -v` to reset. | SC-10, SC-16 |

---

## 8. What We Will NOT Do (with time rationale)

Matches spec.md X-1 through X-11. Each entry adds a time estimate — what would be saved by skipping vs. what it would cost to implement.

| # | Exclusion | Time saved | Cost to implement | Why now | Trace |
|---|-----------|------------|-------------------|---------|-------|
| X-1 | Authentication / authorization | ~2 hours | Token generation, middleware, test coverage, README docs | Explicitly skipped by brief. Demo audience is the interviewer, not a public user. | Brief §"Skip" |
| X-2 | Webhook signature verification | ~1.5 hours | HMAC validation, secret management, replay adjustment | Carrier trust assumed for demo. Replay tool is the only "carrier" in practice. | Brief |
| X-3 | Deployment beyond local Docker Compose | ~3 hours | Multi-env config, secrets, CI/CD, cloud provisioning | Deliverable is a local demo, not production. | Brief |
| X-4 | Multi-tenancy | ~4 hours | Tenant model, scoping, migration, isolation tests | One flat namespace. Interview extension topic (not implementation). | Brief |
| X-5 | Rate limiting | ~1 hour | Rack middleware or gem, config, tests | ~1,000 events once, not sustained traffic. | Brief |
| X-6 | Admin UI | ~5 hours | Views, assets, auth, CRUD | API-only. curl and replay tool provide all interaction. | Brief |
| X-7 | Status-transition state machine | ~2 hours | Transition table, validation, error codes | Timestamp derivation is simpler and correct (spec.md §6 rationale). | Spec X-7, FR-6 |
| X-8 | Email / webhook notifications | ~2 hours | Mailer, job queue, webhook sender | Not requested. | Brief |
| X-9 | Event mutation (PATCH/DELETE) | ~1 hour | Update/delete endpoints, immutability enforcement | Events are immutable — simplifies concurrency and correctness. | Spec X-9 |
| X-10 | Standalone shipment creation | ~0.5 hour | POST /shipments endpoint | Shipments auto-created on first event. No standalone creation needed. | Spec X-10 |
| X-11 | Pagination | ~1 hour | Page/per_page params, count queries, response metadata | 310 items → one page. Trade-off table #10. | Spec X-11 |

**Total time saved by skipping: ~23 hours.** Entire project fits within the ~6–12 hour timebox because these are explicitly excluded.

---

## 9. Traceability Matrix

Every spec.md Functional Requirement maps to one or more plan sections.

| FR | Requirement | Plan section(s) | Verification |
|----|-------------|-----------------|--------------|
| FR-1 | Accept valid event(s), create shipment | §1 (call chain), §2 (DDL), §3.1 (transaction), §4.1 (API single+batch) | SC-1, SC-18 |
| FR-2 | Reject invalid/missing fields | §4.1 (validation rules, 422) | SC-8 |
| FR-3 | Reject non-JSON body | §4.1 (400, rescue ParseError) | SC-7, SC-8, SC-9 (error-response SCs) |
| FR-4 | Duplicate event_id → 200 no-op | §2 (UNIQUE index), §3.2 (insert-then-rescue), §4.1 (200 response) | SC-2 |
| FR-5 | Concurrent duplicates → one row | §2 (UNIQUE index), §3.2 (race-free defense chain) | SC-2, SC-10 (concurrent replay) |
| FR-6 | current_status from max timestamp | §1 (query-time derivation), §3.3 (concurrent safety), Trade-off #1 | SC-5 |
| FR-7 | Timestamp tie-break | §1 (derivation), Trade-off #1 (no persisted status) | SC-4, SC-5 (timeline order + current_status correctness) |
| FR-8 | Ordered timeline + 404 | §2 (composite index), §4.2 (API) | SC-4 |
| FR-9 | Filter by status, sorted by reference | §1 (eager-load + Ruby filter), §4.3 (API), Trade-off #3 | SC-6, SC-17 |
| FR-10 | Invalid status filter → 400 | §4.3 (API validation) | SC-7 |
| FR-11 | UTC Z-suffix only, reject offsets | §2 (VARCHAR storage), §4.1 (regex validation), Trade-off #7 | SC-9 |
| FR-12 | Replay: shuffle, concurrent, compare to expected state | §5 (replay algorithm), Trade-off #5, #6, #12 | SC-10, SC-13 |
| FR-13 | Replay summary line | §5 (step 6-7, exit code) | SC-10, SC-11 |
| FR-14 | Replay idempotency | §5 (two-pass verification) | SC-11, SC-12 |

Every SC also maps:

| SC | Plan section(s) |
|----|----------------|
| SC-1 | §1, §2, §4.1 |
| SC-2 | §3.2, §4.1 |
| SC-3 | §1 (derivation rule), §3.3 |
| SC-4 | §2 (composite index), §4.2 |
| SC-5 | §1 (query-time), §5.3 (oracle) |
| SC-6 | §4.3, Trade-off #3 |
| SC-7 | §4.3 |
| SC-8 | §4.1 |
| SC-9 | §4.1, Trade-off #7 |
| SC-10 | §5, Trade-off #5 |
| SC-11 | §5.2 |
| SC-12 | §5.2 |
| SC-13 | §5.1 (seed) |
| SC-14 | §5, Trade-off #11 |
| SC-15 | §8 (X-11 excluded → test DB separate) |
| SC-16 | §4.2 (404), §2 (empty DB → no rows) |
| SC-17 | §4.3 (empty list), Trade-off #3 |
| SC-18 | §4.1 (batch ingestion) |

---

## 10. Verification Commands (Plan-level)

| What | Command | Expected |
|------|---------|----------|
| EXPECTED_CMD runs in app container | `docker compose exec -T app ruby bin/generate_expected.rb` (see spec.md §5) | Writes `.spec/expected_state.json` with 310 shipments, 941 events |
| EXPECTED_CMD is independent | `grep -r "expected_state" lib/ app/` | Zero matches — Rails app never references expected_state.json |
| Migration creates correct schema | `bin/rails db:migrate && bin/rails runner "puts Shipment.columns.map(&:name); puts Event.columns.map(&:name)"` | shipments: id, reference, created_at, updated_at; events: id, event_id, shipment_reference, status, event_timestamp, created_at, updated_at |
| Indexes exist | `bin/rails runner "puts ActiveRecord::Base.connection.indexes(:events).map(&:name)"` | `idx_events_event_id`, `idx_events_ship_ts` |
| Indexes exist | `bin/rails runner "puts ActiveRecord::Base.connection.indexes(:shipments).map(&:name)"` | `idx_shipments_reference` |
| Replay runs | `bin/rake replay:full SEED=42 CONCURRENCY=10` | exit 0, `310/310` |
| Test suite runs | `bin/rails test` | exit 0, all tests pass |

---

> **Gate:** Trade-off table: 12 rows, each with reconsideration trigger. Risk register: 7 rows. Traceability matrix covers all 14 FRs and all 17 SCs. Awaiting your review before Phase 3 (Tasks).
