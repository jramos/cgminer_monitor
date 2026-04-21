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
| HttpApp state lives in Sinatra settings (poller, started_at, configured_miners) | `architecture.md`, `components.md`, `interfaces.md` | consistent |

Nothing contradictory. If later edits introduce drift, re-run this section.

## Completeness gaps

Areas where the code hasn't fully settled a question, or where the docs are correctly describing a known fuzzy area. (Gaps 1–3 and 5, 9 from the original pass have been addressed; see `CHANGELOG.md` Unreleased section.)

### 1. Mongo 5.0 floor is asserted but not tested in CI
The CI matrix uses Mongo 6 and 7 because 5.0 isn't available as a GitHub Actions service container. A regression that broke 5.0 while remaining compatible with 6.0 wouldn't be caught. If 5.0 support is load-bearing for any user, add a spec that uses a locally-pulled Mongo 5 image (outside GitHub Actions services).

### 2. Thread safety of `Config.current` memoization
`Config.current ||= from_env` is a classic lazy init that isn't thread-safe if called concurrently by multiple threads on the first call. In practice, `Server` always hits `Config.current` through the main thread before the Poller or Puma threads start, so this is not currently exploitable. But there's no lock; if a future refactor has the Poller initialize concurrently with `HttpApp`'s settings being populated in `Server#run`, the race could surface. Consider a `Mutex` around the memoization or early-init in `Server#run`.

### 3. No shutdown path for migrate/doctor subcommands
`cgminer_monitor migrate` and `doctor` install Mongoid clients and exit. Mongoid's driver keeps background connection monitors running in threads, which can delay Ruby process exit briefly. Not broken — just sometimes a surprising few-second pause before shell prompt returns. No action needed unless it bites someone.

### 4. ~~`HttpApp#configured_miners_cache` is loaded from disk at first request~~ — RESOLVED
`Server#run` now eager-populates `settings.configured_miners` via `HttpApp.parse_miners_file` before Puma accepts its first request, so the first-request-reads-YAML hazard is gone.

### 5. No integration test for `run` with real signal delivery
`spec/integration/cli_spec.rb` tests `migrate`, `doctor`, `version`, and the deprecated shims by spawning subprocesses. But it doesn't test `run` end-to-end (start, poll, SIGTERM, clean shutdown). Orchestrating signal delivery from a spec process is fiddly but doable; until then, the shutdown path is only exercised by the unit specs for `Server`, which mock the Puma launcher.

## Language and tooling limitations

- **Ruby-only** — no FFI, no native extensions.
- **macOS and Linux only in practice.** Windows isn't explicitly unsupported but isn't tested.
- **CI only on ubuntu-24.04.**
- **Integration tests require MongoDB running.** There's no embedded-Mongo fallback.

## Recommendations

Medium effort, possibly worth it:
1. Add a spec that exercises `Server#run` end-to-end with real signal delivery.
2. ~~Replace `HttpApp.configured_miners_cache` with an instance variable set explicitly by `Server#run`.~~ Done — `HttpApp` class-level state moved to Sinatra `settings`, populated by `Server#run`. See Unreleased CHANGELOG.

Higher effort, defer:
3. Add a Mongo 5.0 CI lane (outside GitHub Actions services) so the 5.0 floor claim is actually enforced.
4. Revisit the `Config.current` memoization thread-safety if the process model ever changes.

## How I validated

- Read every file under `lib/`, `bin/`, `spec/support/`, the CI workflow, `Rakefile`, `.rubocop.yml`, `.rspec`, `Gemfile`, the gemspec, the Dockerfile and compose file, `config/miners.yml.example`, README, CHANGELOG, MIGRATION.
- Did not run the test suite as part of writing these docs. "Tested" claims are derived from reading the specs and the CI workflow, not from a pass/fail run.
- Did not verify the OpenAPI spec's contents against each route response shape — only the existence-and-presence guard that `spec/openapi_consistency_spec.rb` enforces.
