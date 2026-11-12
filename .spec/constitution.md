# Project Constitution — Shipment Events Service

> Read-only. Ratified: 2026-11-12 (Phase 0).
> Every clause below carries a verifiable check. Clauses without one were deleted and listed at the end.

---

## MUST Clauses

### 1. Machine-verifiable acceptance criteria
**MUST** — Every acceptance criterion in `spec.md` and `README.md` must be phrased as a testable assertion with an unambiguous pass/fail command or query. Subjective descriptors such as "good performance," "clean code," "correctly handled," "elegant," "robust," "should be," "ought to," or "nice to have" are forbidden in any acceptance context.

**Verification** — `rg -n "good performance|clean code|correctly handled|elegant|robust|should be|ought to|nice to have" .spec/spec.md README.md` returns zero matches in sections labelled Acceptance / Verification.

---

### 2. Runtime verification only
**MUST** — Any claim of correctness or "verification passed" must cite actual command output captured from the target runtime (Rails server + PostgreSQL). Static reading of source code alone does not constitute verification.

**Verification** — Every verification entry in `.spec/progress.md` must include a concrete shell command and its condensed output, not a file-path reference alone. A missing command or fabricated output is a violation.

---

### 3. Full correctness replay
**MUST** — The correctness replay must satisfy all of:
- (a) start from an empty database (zero shipments, zero events);
- (b) use multi-threaded concurrent HTTP POSTs to the ingestion endpoint;
- (c) use a fixed, documented random seed to shuffle CSV row order;
- (d) shuffle the input rows before replay;
- (e) include all 56 duplicate `event_id` rows from `carrier_events.csv`;
- (f) run the full replay twice consecutively;
- (g) the second run must produce zero new rows in the events table and zero shipment-state changes.

**Verification** — Execute the documented replay command twice. Assert: (1) exit code 0 on both runs; (2) stdout of run 2 contains "0 new events" or equivalent; (3) `SELECT count(*) FROM events` is identical after runs 1 and 2; (4) `SELECT count(*) FROM shipments` is identical after runs 1 and 2.

---

### 4. Demo / test data isolation
**MUST** — The demo database and the test database must be physically separate. Running the test suite must leave the demo database entirely intact. After tests complete, the demo database must still pass the full correctness replay (Clause 3).

**Verification** — (a) `config/database.yml` shows distinct database names for development and test; (b) after `bin/rails test`, re-run the replay verification (Clause 3) against the development database and confirm identical results; (c) `SELECT count(*) FROM events` in the development database must be unchanged from before the test run.

---

### 5. README runtime honesty
**MUST** — Every target runtime declared in `README.md` (e.g. "Docker Compose", "local Rails + PG") must be exercised with its exact documented startup command at least once before the project is declared complete.

**Verification** — Cross-reference the "How to run" section of `README.md` against `.spec/progress.md`: each declared runtime must appear in a verification entry that includes the startup command and its output.

---

### 6. One-command demo is the highest-priority deliverable
**MUST** — There must exist a single documented command that starts the entire stack (service + database), replays the full `carrier_events.csv`, and prints a machine- and human-readable correctness summary. This command must never exit silently with code 0 — it must produce output that allows a reviewer to judge pass/fail without reading source code.

**Verification** — Run the one-liner from README on a clean checkout. Assert: exit code 0; stdout contains a summary line matching the pattern `310/310 shipments verified` or equivalent; stderr contains no fatal errors.

---

### 7. No unrequired dependencies
**MUST NOT** — Do not introduce any gem, library, or infrastructure component not explicitly needed by the assignment brief: Ruby on Rails, PostgreSQL, CSV data file, and the replay tooling. Any additional dependency must be documented in the ADR with a one-paragraph trade-off rationale that references the specific problem the dependency solves and why a built-in or simpler alternative was rejected.

**Verification** — (a) `Gemfile` diff vs `rails new` defaults shows only Rails-standard gems plus explicitly ADR-justified additions; (b) every non-default gem entry has a corresponding section in `ADR.md`; (c) no service containers beyond Rails app + PostgreSQL appear in `compose.yaml`.

---

### 8. Replay idempotency
**MUST** — The replay tooling must be idempotent: running it N times against the same database must produce unchanged shipment states and no new event rows after the first run.

**Verification** — Run replay 3 times consecutively. After each run, capture `SELECT count(*), max(updated_at) FROM events`. Assert: count is identical across runs 2 and 3; `max(updated_at)` is identical across runs 2 and 3.

---

### 9. Constitution is self-policing
**MUST** — Every MUST / MUST NOT clause in this file must include a verifiable check line that references a concrete command, file check, or query. Clauses that could not be assigned a verification method were deleted and are listed in the Removed Clauses section below.

**Verification** — Self-referential: all 9 clauses above carry a verifiable check line. Absence of one is a violation.
