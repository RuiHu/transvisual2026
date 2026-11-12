# AI Usage Note

## Tool

This project was built with **Codex CLI** (DeepSeek-V4-Pro & DeepSeek-V4.1-Flash) as an AI pairing
engineer. The AI:

- wrote all implementation code (controllers, models, rake tasks, specs,
  verify.sh, bin/demo, DEMO.md);
- executed every verification command and reported raw stdout;
- co-authored and refined the formal specification documents (constitution.md,
  spec.md, plan.md, tasks.md) through multiple review rounds.

The human:

- made all architectural and trade-off decisions;
- defined the spec-driven gates and rejected work that did not pass them;
- reviewed every AI-generated file before acceptance.

## Three things the AI got wrong and how each was caught

### 1. Backticks used as Python string quotes

The first `EXPECTED_CMD` draft used backticks as Python string delimiters
(`open(\`carrier_events.csv\`)`). This is a real Python `SyntaxError`.

- Caught by: the static linter `.spec/verify.sh` check C12 and a manual
  `compile()` attempt.
- Fix: replaced all 59 backticks with single quotes, then later replaced the
  Python oracle with a Ruby script (`bin/generate_expected.rb`) when it became
  clear the host had no usable Python runtime.

### 2. Concurrent shipment creation aborted PostgreSQL transactions

During the first full replay, 4 events produced HTTP 500s and verification
reported 306/310 instead of 310/310.

- Root cause: two threads trying `INSERT` on the same `shipments(reference)`
  UNIQUE index inside the same PG transaction caused the whole transaction to
  become aborted.
- Caught by: the replay output itself (`error_count=4`, `306/310`).
- Fix: wrapped shipment creation in a savepoint (`requires_new: true`).

### 3. RSpec ran in the development environment, truncating the demo database

The `rails_helper.rb` used `ENV["RAILS_ENV"] ||= "test"`, but Docker Compose
already injected `RAILS_ENV=development`. The suite ran against `app_development`
and every `before(:each)` truncated the tables.

- Caught by: counting rows in the development database before and after running
  specs (`SELECT count(*)` → 0 after a green run).
- Fix: forced `ENV["RAILS_ENV"] = "test"` and always pass `-e RAILS_ENV=test`
  to `docker compose exec`. Restored demo data with `./bin/demo --no-reset`.

## AI-first workflow

Every phase followed a spec-driven gate model:

1. The human defined the constitution and acceptance criteria.
2. The AI proposed code, specs, and verification commands.
3. The human reviewed output and rejected or requested changes.
4. Only commands that produced real stdout were considered evidence.

