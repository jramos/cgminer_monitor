# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`bundle-audit` in CI** (`.github/workflows/ci.yml`). New `audit`
  job runs `bundle exec bundle-audit check --update` on every push
  and PR, gating merges on known CVEs in `Gemfile.lock`. Advisory
  DB is refreshed on each run. Also available locally as
  `bundle exec rake audit`.
- **Dependabot config** (`.github/dependabot.yml`). Weekly bump PRs
  for Bundler, GitHub Actions, and Docker `FROM` base images, with
  `open-pull-requests-limit: 3` per ecosystem. `versioning-strategy:
  lockfile-only` on bundler keeps gemspec `~>` bounds stable — the
  lockfile moves forward automatically, but a human widens bounds
  when intent is to adopt a new line. PRs target `develop`.

## [1.1.0] — 2026-04-22

### Added
- **`miners.yml` hot reload via SIGHUP.** Add or remove a miner without
  restarting the service. The Server traps SIGHUP, atomically rebuilds
  the Poller's `MinerPool` and swaps `HttpApp.settings.configured_miners`
  — the next poll tick and every subsequent HTTP request see the new
  list. `Poller#reload!` builds a new `MinerPool` and swaps the ivar
  (the old pool is never mutated in place, so an in-flight `poll_once`
  that captured it as a local finishes consistently). Parse or
  validation failures log `event=reload.failed` and keep the previous
  list so a typo can't crash a running server. When `Poller` and
  `HttpApp` reloads disagree (one succeeded, the other didn't), the
  dispatcher logs `event=reload.partial` at error level so operators
  see the inconsistent state instead of inferring it. New CLI verb
  `cgminer_monitor reload` reads `CGMINER_MONITOR_PID_FILE`,
  dry-run-parses miners.yml locally (surfacing typos at exit 78 before
  signaling), and sends SIGHUP; `doctor` reports the PID file's
  posture (`not configured` / `OK (pid N)` / `STALE` / `UNOWNED` /
  `INVALID` / `MISSING`). Reload-verb failure modes now exit 1 with
  a clean message instead of a stack trace for
  `ArgumentError` (garbage pid-file contents) and `Errno::EPERM`
  (pid belongs to another user). `parse_miners_file` and
  `build_miner_pool` now validate the top-level YAML shape up-front
  and raise `ConfigError` with a specific message, replacing the
  fragile `rescue NoMethodError` that previously hid method-rename
  bugs.

### Changed
- **Server signal dispatcher uses `launcher.events.on_booted` instead
  of `sleep(0.05)`.** Puma's `setup_signals` unconditionally installs
  its own SIGHUP handler that calls `stop()` when `stdout_redirect` is
  unset; the old sleep-based wait could race and leave Puma's HUP
  handler active, eating reload signals. `on_booted` is deterministic.
  Shutdown (SIGTERM/SIGINT) behavior unchanged.
- **`HttpApp` class-level state moved to Sinatra `settings`.** `poller`,
  `started_at`, and `configured_miners` are now declared via `set :key,
  nil` on the class and written via `HttpApp.set :key, value` in
  `Server#run`. Routes read via `settings.foo` instead of
  `self.class.foo`. `configured_miners` is now eager-loaded by
  `Server#run` (via `HttpApp.parse_miners_file`) rather than lazily on
  first request.
  - New class method `HttpApp.configure_for_test!(miners:, poller:,
    started_at:)` bundles the three settings writes that tests used to
    do one-by-one.
  - Removed: `HttpApp.poller=` / `HttpApp.started_at=` / the
    `HttpApp.configured_miners_cache` memo / `HttpApp.reset_configured_miners!`
    helper. Specs that called any of these should switch to
    `configure_for_test!`.

### Added
- AI-assistant knowledge base under `docs/` (architecture, components,
  interfaces, data models, workflows, dependencies, review notes,
  plus an `index.md` router) and a consolidated `AGENTS.md` at the
  repo root. Not packaged in the gem.
- README subsections for CLI exit codes (0/1/64/78) and structured
  logging, plus a Further Reading section linking to CHANGELOG,
  MIGRATION, AGENTS, and docs/.
- Code comment on `Poller#to_numeric` documenting the
  drop-non-numeric-values policy used by sample extraction.

### Removed
- Unused `CgminerMonitor::StorageError` and
  `CgminerMonitor::PollError` classes. Declared during the 1.0
  rewrite but never raised by any code path. Callers using
  `rescue CgminerMonitor::Error` are unaffected.
- `CgminerMonitor::Server.started_at` and
  `CgminerMonitor::Server.poller` class accessors. They mirrored
  the `HttpApp` ones but were never read; the canonical readers
  remain on `HttpApp`.
- Undocumented-and-unwired `DEBUG` env var row from the README.
  `Server#run` already logs backtraces on `server.crash`
  unconditionally; no runtime toggle exists to control it.

### Fixed
- Dockerfile now generates a `cgminer_monitor` binstub during the
  builder stage so `bundle exec cgminer_monitor <verb>` works inside
  the image. Previously only the default ENTRYPOINT worked: running
  any non-default verb (e.g. `migrate`, `version`) failed with
  `bundler: command not found: cgminer_monitor`, because the gem's
  executable was not installed on the image's PATH.
- `docker-compose.yml` now overrides the Dockerfile's exec-form
  ENTRYPOINT with `["sh", "-c"]` so the `migrate && run` chain
  actually executes. Previously the chained command was appended to
  the ENTRYPOINT as argv, leaving `cgminer_monitor` to receive `sh`
  as its first argument and exit 64 (unknown command).

## [1.0.0] - 2026-04-15

### Breaking changes
- cgminer_monitor is now a **standalone HTTP service**, not a Rails engine. See [MIGRATION.md](MIGRATION.md) for upgrade instructions.
- Removed the `CgminerMonitor::Engine`, all Rails controllers, and the v1 API (`/cgminer_monitor/api/v1/*`).
- Removed `CgminerMonitor::Document` hierarchy (`Summary`, `Devs`, `Pools`, `Stats`, `Log`). Data is now stored in `samples` (time-series) and `latest_snapshot` (current-state) collections.
- Removed `CgminerMonitor::Daemon` (start/stop/restart/status). Use `cgminer_monitor run` as a foreground process under your supervisor.
- Removed `CgminerMonitor::Logger` (the old polling class). Replaced by `CgminerMonitor::Poller`.
- Removed all rake tasks (`cgminer_monitor:create_indexes`, `cgminer_monitor:delete_logs`). Use `cgminer_monitor migrate` CLI command instead.
- Removed `rails` runtime dependency.
- Removed `config/mongoid.yml` — Mongoid is configured programmatically from `CGMINER_MONITOR_MONGO_URL`.
- Ruby 3.2+ required (was Ruby 2.0).
- MongoDB 5.0+ required (was MongoDB 2.6).

### Added
- Standalone HTTP API (Sinatra + Puma) with v2 endpoints.
- `GET /v2/healthz` — liveness/readiness with starting/healthy/degraded states.
- `GET /v2/metrics` — Prometheus text exposition endpoint.
- `GET /v2/miners` — list configured miners with availability.
- `GET /v2/miners/:miner/{summary,devices,pools,stats}` — current-state snapshots.
- `GET /v2/graph_data/{hashrate,temperature,availability}` — time-series queries with ISO-8601 and relative time range parameters.
- `GET /openapi.yml` and `GET /docs` — OpenAPI 3.1 spec and Swagger UI.
- `cgminer_monitor run` — foreground server with graceful SIGTERM/SIGINT shutdown.
- `cgminer_monitor migrate` — idempotent collection and index creation.
- `cgminer_monitor doctor` — config validation, Mongo and miner connectivity checks.
- `CgminerMonitor::Poller` — polls all configured miners, extracts numeric samples, writes to Mongo.
- `CgminerMonitor::Sample` — Mongoid model for the `samples` time-series collection.
- `CgminerMonitor::Snapshot` — Mongoid model for the `latest_snapshot` collection.
- `CgminerMonitor::SampleQuery` / `CgminerMonitor::SnapshotQuery` — read-side query modules.
- `CgminerMonitor::Config` — `Data.define` config object from environment variables.
- `CgminerMonitor::Logger` — structured JSON/text logger (module, not the old polling class).
- Environment variable configuration (see README.md for the full table).
- CORS support via `rack-cors`.
- Dockerfile (multi-stage) and docker-compose.yml with Mongo, cgminer_monitor, and optional FakeCgminer services.
- Integration test suite: full pipeline, healthz states, CLI subprocess tests.
- OpenAPI consistency spec — CI guard that routes and openapi.yml stay in sync.
- GitHub Actions CI matrix: Ruby 3.2/3.3/3.4 + Mongo 6/7 (4.0 and head best-effort).
- SimpleCov coverage tracking.
- RuboCop with project-tuned config.

### Changed
- `cgminer_api_client` dependency bumped to `~> 0.3.0`.
- `mongoid` dependency bumped to `~> 9.0`.
- Gemspec modernized: `required_ruby_version`, metadata URIs, `rubygems_mfa_required`.

### Known constraints
- Mongoid 9 caps `bson < 6`. When bson 6 is released, cgminer_monitor cannot accept it until Mongoid 10 lands.
- Mongoid 9's upstream CI only tests Ruby 3.3. Ruby 3.4 compatibility is asserted by our CI matrix but not by upstream; Ruby 4.0 and head are best-effort-only.
- MongoDB 5.0 minimum is required for time-series collections. 6.0 is the closest version testable in GitHub Actions services; the floor claim is tested against 6.0 in CI as a proxy.
- cgminer_api_client's `MinerPool#query` spawns one thread per miner with no upper bound. Not a problem at the expected scale (<=10 miners) but documented so that operators running >50 miners are aware.

### Migration guide
See [MIGRATION.md](MIGRATION.md) for a detailed guide on upgrading from 0.x.
