# Shipment Events Service

> **See also:** [5-minute demo guide](DEMO.md) · [ADR](ADR.md) · [AI usage note](AI_USAGE.md)

Ingests carrier shipment-tracking events (duplicates and out-of-order rows included)
and serves an accurate shipment timeline with a derived current status.

Rails 7.1 API-only · PostgreSQL 16 · Docker Compose · RSpec.

## One-command demo

```sh
./bin/demo
```

`./bin/demo` resets the database volume, builds and starts the stack, generates the
independent expected-state snapshot, then replays `carrier_events.csv` and verifies
all shipments. Use `./bin/demo --no-reset` to keep existing data (the replay then
reports `0 new events`).

Equivalent manual sequence:

```sh
docker compose down -v \
  && docker compose up -d --wait \
  && docker compose exec -T app ruby bin/generate_expected.rb \
  && docker compose exec -T app bin/rake replay:full SEED=42 CONCURRENCY=10
```

Expected summary lines:

```
expected_state.json written: 310 shipments, 941 events
seed=42 threads=10 shuffled=true
941 new, 56 duplicates
310/310 shipments verified
```

Exit code 0 means every shipment matches the independent expected-state snapshot.
Run the replay command a second time and it prints `0 new events` with the same
`310/310 shipments verified`.

### Step by step (same commands)

```sh
docker compose down -v
docker compose up -d --wait
docker compose exec app bin/rails db:migrate
docker compose exec app ruby bin/generate_expected.rb
docker compose exec app bin/rake replay:full SEED=42 CONCURRENCY=10
```

## HTTP API

| Method | Path | Behaviour |
|--------|------|-----------|
| POST | `/api/v1/events` | Ingest one event. `201` new, `200 {"duplicate":true}` on a repeated `event_id`, `422` invalid, `400` malformed body. |
| POST | `/api/v1/events` | Batch body `{"events":[...]}` → `200 {accepted, inserted, duplicates, failed}`; per-event idempotency applies. |
| GET | `/api/v1/shipments/:reference/timeline` | Events ordered by timestamp, plus derived `current_status`; `404` if unknown. |
| GET | `/api/v1/shipments?status=<status>` | Shipment list with derived status; `400` for an unknown status value. |
| GET | `/health` | DB connectivity probe. |

Valid statuses: `created`, `picked_up`, `in_transit`, `delivered`, `failed`.

## Key decisions

- **Minimal gems.** `rails`, `pg`, `puma`, `csv`, `tzinfo-data` (+ `rspec-rails` in
  development/test). No auth, background jobs, or admin UI — the brief excludes them.
- **Idempotency is a database invariant.** `events.event_id` has a UNIQUE index;
  duplicate delivery is decided by PostgreSQL, not by an application-level
  check-then-insert. Concurrent identical posts resolve to one row.
- **Current status is derived, never cached.** `current_status` is computed at query
  time from the event with the greatest `(event_timestamp, event_id)`. This removes
  write–write races between concurrent events for the same shipment.
- **Late and out-of-order events are accepted.** There is no status-transition state
  machine; the timeline is ordered by timestamps, so a late `picked_up` still appears
  in the correct position without changing the terminal status.
- **Batch delivery is supported** with the same per-event rules and reported counts.
- **Three indexes only:** `events(event_id)` UNIQUE (idempotency),
  `events(shipment_reference, event_timestamp)` (timeline + derivation),
  `shipments(reference)` UNIQUE (find-or-create).
- **Independent oracle.** `bin/generate_expected.rb` reads only
  `carrier_events.csv` with the Ruby stdlib (CSV/JSON), writes
  `.spec/expected_state.json`, and shares no code with the app. Replay compares API
  output against it.
- **No pagination** on `GET /shipments` — 310 rows fit one response (brief excludes it).

## Tests

```sh
docker compose exec -T -e RAILS_ENV=test app bundle exec rspec
```

Expected: `8 examples, 0 failures`. The suite covers duplicate `event_id`,
12-thread concurrent duplicates, first-write-wins, batch idempotency, 422 with no
side effects, unknown-shipment 404, and late/out-of-order timeline ordering.

The demo database (`app_development`) is separate from the test database
(`app_test`); running the suite must leave the demo data intact.

## API smoke test

With the stack running:

```sh
./bin/api-smoke
```

Checks, against `BASE_URL` (default `http://localhost:3000`):

- `/health`;
- single create `201`, duplicate `200` + `duplicate:true`, first payload wins;
- missing fields / non-UTC timestamp `422`, non-JSON body `400`;
- batch twice: `inserted` 2 → 0, `duplicates` 1 → 3;
- timeline order with out-of-order writes, `current_status`;
- list with `status=` filter, invalid filter `400`, unknown shipment `404`;
- 12 concurrent posts of one `event_id`: one `201`, eleven `200`, one stored row.

The script tags rows as `TV-SMOKE-<timestamp>-…` and does not delete them.

## What I'd do next

1. OpenAPI spec generation before integrating an external consumer.
2. Multi-seed replay matrix (e.g. SEED=1..100) for statistical confidence.
3. Incremental projection / replay-only-new-events for datasets above ~10k rows.
4. CI pipeline running RSpec + replay verification on every push.
5. Async ingestion pipeline (per the ADR design note), not implemented here.
6. Pagination once shipments exceed a few hundred.
7. Rate limiting and webhook signature verification for untrusted carriers.

## AI usage note

This project was built with Codex (OpenAI) as a pairing engineer. Spec, plan, tasks,
scaffold, replay tooling, and the RSpec suite were AI-generated and reviewed line by
line; every verification claim in this repo comes from an actually executed command.

Three AI mistakes were caught by running things, not by reading code:

1. **Backticks used as Python string quotes** in the first EXPECTED_CMD draft — a real
   `SyntaxError`. Caught by the static linter (`verify.sh` C12) and fixed to quotes.
2. **Concurrent first-event creation** aborted the PostgreSQL transaction after a
   unique violation, producing 4 HTTP 500s and `306/310` on the first full replay.
   Caught by the replay output; fixed with a savepoint around shipment creation.
3. **RSpec ran in `development`** because `ENV["RAILS_ENV"] ||= "test"` respected the
   Compose-provided `RAILS_ENV=development`; the suite truncated the demo DB. Caught
   by pre/post row counts; fixed by forcing `RAILS_ENV=test` and restored via replay.

## Layout

```
app/controllers/api/v1/   events + shipments endpoints
app/models/               Shipment, Event
bin/generate_expected.rb  independent oracle from carrier_events.csv
lib/tasks/replay.rake     replay:full (deliver + verify), replay:verify (verify only)
spec/                     RSpec request specs
.spec/                    constitution, spec, plan, tasks, verify.sh, progress log
```
