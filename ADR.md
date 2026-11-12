# Architecture Decision Record — Shipment Events Service

## ADR-001: Idempotency authority is a database unique index

Context: carrier_events.csv contains 56 duplicate `event_id` rows placed up to 837
lines apart. A time-window or in-memory dedup scheme would miss these.

Decision: a UNIQUE index on `events(event_id)`. Duplicate delivery is decided by
PostgreSQL, not by application-level check-then-insert. The controller uses
`create!`-then-rescue rather than `find_or_create_by!` to avoid TOCTOU races under
concurrent replay.

Alternatives: (a) application-level dedup with a Redis set — time-bound window,
not durable; (b) `before_create` callback — not concurrency-safe.

Consequence: every POST pays the index write; the benefit is that idempotency
survives any arrival pattern (sequential, concurrent, days apart) zero-handed.

## ADR-002: Current status is derived at query time, never cached

Context: when two events for the same shipment arrive concurrently in separate
transactions, a cached `current_status` on `shipments` would experience a
write–write race — the last committer overwrites with a potentially stale value.

Decision: `Shipment#current_status` is computed from the events table at query
time (`ORDER BY event_timestamp DESC, event_id DESC LIMIT 1`). No `current_status`
column exists on the shipments table.

Alternatives: (a) cached column with `SELECT ... FOR UPDATE` — creates lock
contention; (b) database trigger — opaque and harder to test; (c) eventual-consistency
cache — adds complexity this demo does not need.

Consequence: the status-filtered list must load all events into memory (941 rows)
and filter in Ruby. At 310 shipments this is ~5 ms; see ADR-005 for production path.

## ADR-003: Shipment creation uses a savepoint to survive concurrent first-write

Context: the first event for a new `shipment_reference` must create the shipment
row in the same transaction. Under concurrent replay, two threads may both attempt
`INSERT` on the UNIQUE `shipments(reference)` index. A plain `CREATE` inside the
outer transaction would raise a unique violation that **aborts the whole
transaction** — every later query in that transaction fails. This was caught by the
replay producing 4 HTTP 500s and 306/310 on the first full run.

Decision: shipment creation is wrapped in
`Shipment.transaction(requires_new: true)` (a savepoint). On unique violation, only
the savepoint rolls back; the outer transaction remains usable, the loser re-reads
the committed row, and event insertion proceeds normally.

Consequence: adds one SAVEPOINT per first-write for a new shipment (310 in the
replay) — negligible overhead. The logic is isolated in `ensure_shipment!`.

## ADR-004: Independent oracle is a Ruby script sharing no code with the app

Context: correctness must be checked against a source of truth that is not the
system itself (spec.md §5).

Decision: a standalone Ruby script (`bin/generate_expected.rb`) that reads only
`carrier_events.csv` with the stdlib (csv, json). It deduplicates, sorts by the
same tie-break (`event_timestamp, event_id`) as the application, and writes
`.spec/expected_state.json`. The script never `require`s Rails; it shares zero
code paths with the ingestion or query logic.

Alternatives: (a) Python oracle — host has no usable Python runtime; (b) Node
oracle — would split runtime across host/container without benefit.

Consequence: oracle and application share the same Ruby interpreter and CSV
stdlib, but share no code. A stdlib bug could theoretically affect both; acceptable
residual risk for a take-home demo; mitigable with a Python cross-check in CI.

## ADR-005: Async ingestion pipeline (design note, not implemented)

When volume grows beyond what a synchronous HTTP API can handle, processing moves
to an async pipeline:

1. **Ingest stays in Rails API.** Every event is still written to `events` with the
   same idempotency guard. One new table: `event_outbox` (event_id, processed_at),
   written atomically inside the same transaction.
2. **Outbox poller** (background process, e.g. good_job) selects unprocessed
   `event_outbox` rows in `created_at` order, publishes them to a broker (Redis
   Streams / SQS), and marks `processed_at`.
3. **Projection worker** consumes the stream, updates a cached
   `shipments.current_status` column with the latest `(event_timestamp, event_id)`
   per shipment. Re-processing an event must not regress the cached status —
   enforced by storing the projected `event_timestamp` and skipping events earlier
   than the current projection.
4. **Read path** goes against the cached column. A `stale_since` timestamp on the
   shipment row tells the reader when the last projection ran.

Trades: write path stays ACID (same schema). Read path becomes eventually
consistent but horizontally scalable. The outbox ensures no event is lost between
writing and publishing.

---

See `.spec/plan.md` §6 for the complete trade-off table (12 decisions, each with
a reconsideration trigger).
