# Review Notes

Self-audit of the documentation set. Honest list of what I couldn't fully verify, known gaps, and the items I'd flag for cleanup work. Read this before trusting a confident-sounding claim elsewhere in `docs/`.

## Consistency check

I cross-referenced the following claims across files and found no contradictions:

| Claim | Asserted in | Verified |
|---|---|---|
| Two-thread model (Poller + Puma) | `codebase_info.md`, `architecture.md`, `components.md`, `workflows.md` | consistent |
| `Config` is an immutable `Data.define` | `codebase_info.md`, `architecture.md`, `components.md`, `data_models.md` | consistent |
| Mongoid is configured programmatically from `CGMINER_MONITOR_MONGO_URL` (no `mongoid.yml`) | `codebase_info.md`, `architecture.md`, `interfaces.md`, `dependencies.md` | consistent |
| CLI exit codes 0/1/64/78 | `interfaces.md`, `components.md`, `workflows.md` | consistent |
| `samples` is time-series, `latest_snapshot` is regular | `architecture.md`, `data_models.md`, `components.md`, `dependencies.md` | consistent |
| Ruby 3.2+ / Mongo 5.0+ floors | `codebase_info.md`, `dependencies.md` | consistent |
| Signal-handler reinstall dance after Puma start | `architecture.md`, `components.md`, `workflows.md` | consistent |
| HttpApp has class-level state (poller, started_at, configured_miners_cache) | `architecture.md`, `components.md`, `interfaces.md` | consistent |

Nothing contradictory. If later edits introduce drift, re-run this section.

## Completeness gaps

Areas where the code hasn't fully settled a question, or where the docs are correctly describing a known fuzzy area:

### 1. `DEBUG` env var is documented but not wired
The README's env-var table says `DEBUG=1` gives full backtraces on crashes. In the 1.0.0 code, neither `Config` nor `bin/cgminer_monitor` branches on `DEBUG`. The `Server` already logs full backtraces on `server.crash`, so the behavior happens to match the documented promise — but the control knob doesn't exist. Either wire it up (make backtrace logging conditional) or remove the row from the README.

### 2. `StorageError` and `PollError` are declared but unused
Both classes are defined in `lib/cgminer_monitor/errors.rb` but nothing in `lib/` raises them. `Mongo::Error` is caught at the Poller boundary and logged directly; cgminer errors are captured inside `MinerResult.failure` objects. Either wire these in (rewrap external errors as gem-specific ones), or delete them. Currently they're shelfware.

### 3. `Server.started_at` and `Server.poller` shadow `HttpApp.*`
`Server#run` sets class-level attrs on both `Server` itself and `HttpApp` — same values. `HttpApp` is the reader; `Server`'s copy is never consulted. Low-priority cleanup: remove `Server.started_at` and `Server.poller`, update tests.

### 4. Mongo 5.0 floor is asserted but not tested in CI
The CI matrix uses Mongo 6 and 7 because 5.0 isn't available as a GitHub Actions service container. A regression that broke 5.0 while remaining compatible with 6.0 wouldn't be caught. If 5.0 support is load-bearing for any user, add a spec that uses a locally-pulled Mongo 5 image (outside GitHub Actions services).

### 5. `DEBUG` + backtraces + JSON log format
Even today, `Logger.error` with `backtrace: e.backtrace&.first(10)` produces a `backtrace` JSON array inside the log entry. In `text` format, that shows up as `backtrace=["...", "..."]` (Ruby array stringification). Not ideal for human reading. The "JSON vs text" format choice doesn't really matter at error-time because the backtrace field is always present.

### 6. Thread safety of `Config.current` memoization
`Config.current ||= from_env` is a classic lazy init that isn't thread-safe if called concurrently by multiple threads on the first call. In practice, `Server` always hits `Config.current` through the main thread before the Poller or Puma threads start, so this is not currently exploitable. But there's no lock; if a future refactor has the Poller initialize before `HttpApp.configured_miners_cache` is first touched, the race could surface. Consider a `Mutex` around the memoization or early-init in `Server#run`.

### 7. No shutdown path for migrate/doctor subcommands
`cgminer_monitor migrate` and `doctor` install Mongoid clients and exit. Mongoid's driver keeps background connection monitors running in threads, which can delay Ruby process exit briefly. Not broken — just sometimes a surprising few-second pause before shell prompt returns. No action needed unless it bites someone.

### 8. `HttpApp#configured_miners_cache` is loaded from disk at first request
The cache is lazily built on the first call into `configured_miners`. If the first request comes before the Poller does its first poll, and if `miners.yml` is unreadable by the process (rare), the request would raise. Not observed; flagged as a pedantic correctness note.

### 9. `extract_samples` doesn't document its numeric coercion
`to_numeric(value)` coerces `Integer`/`Float` as-is and tries `Float(value, exception: false)` on strings. Booleans, nil, and other types are silently skipped. This is intentional (we don't want to record `"Y"` or `"Alive"` as samples) but the code has no comment explaining the policy; the `review_notes.md` is the first place it's written down.

### 10. No integration test for `run` with real signal delivery
`spec/integration/cli_spec.rb` tests `migrate`, `doctor`, `version`, and the deprecated shims by spawning subprocesses. But it doesn't test `run` end-to-end (start, poll, SIGTERM, clean shutdown). Orchestrating signal delivery from a spec process is fiddly but doable; until then, the shutdown path is only exercised by the unit specs for `Server`, which mock the Puma launcher.

## Language and tooling limitations

- **Ruby-only** — no FFI, no native extensions.
- **macOS and Linux only in practice.** Windows isn't explicitly unsupported but isn't tested.
- **CI only on ubuntu-24.04.**
- **Integration tests require MongoDB running.** There's no embedded-Mongo fallback.

## Recommendations

Low effort, high value:
1. Wire up `DEBUG=1` in `bin/cgminer_monitor` to gate backtrace logging (or remove it from the README env table).
2. Delete `StorageError` and `PollError` (unless there's a plan to raise them).
3. Remove `Server.started_at` and `Server.poller` class attrs; keep only the `HttpApp` ones.

Medium effort, possibly worth it:
4. Add a spec that exercises `Server#run` end-to-end with real signal delivery.
5. Replace `HttpApp.configured_miners_cache` with an instance variable set explicitly by `Server#run`; keeps the state flow in one place and removes one of the reset-for-tests pitfalls.

Higher effort, defer:
6. Add a Mongo 5.0 CI lane (outside GitHub Actions services) so the 5.0 floor claim is actually enforced.
7. Revisit the `Config.current` memoization thread-safety if the process model ever changes.

## How I validated

- Read every file under `lib/`, `bin/`, `spec/support/`, the CI workflow, `Rakefile`, `.rubocop.yml`, `.rspec`, `Gemfile`, the gemspec, the Dockerfile and compose file, `config/miners.yml.example`, README, CHANGELOG, MIGRATION.
- Did not run the test suite as part of writing these docs. "Tested" claims are derived from reading the specs and the CI workflow, not from a pass/fail run.
- Did not verify the OpenAPI spec's contents against each route response shape — only the existence-and-presence guard that `spec/openapi_consistency_spec.rb` enforces.
