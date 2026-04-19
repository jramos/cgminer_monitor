# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
