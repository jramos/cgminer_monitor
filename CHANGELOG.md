# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **`docs/log_schema.md`** gains a `code` standard key documenting the
  six-symbol vocabulary that consumers (`cgminer_monitor`,
  `cgminer_manager`) emit when wrapping rescued
  `cgminer_api_client::ApiError` exceptions: `access_denied`,
  `invalid_command`, `unknown`, `timeout`, `connection_error`,
  `unexpected`. `poll.miner_failed` gains `code` as an optional
  field; `admin.result` gains `failed_codes` as an optional
  count-by-code map (e.g. `{"access_denied": 3}`). Implementations
  follow in upcoming `cgminer_monitor` and `cgminer_manager`
  releases — schema is a forward-looking contract until then.

## [1.3.2] — 2026-04-25

### Fixed
- **`Dockerfile`** — replaced removed-in-Bundler-4 `bundle binstubs
  --path /usr/local/bundle/bin` with `bundle config set --local bin`
  + plain `bundle binstubs --force`. Was silently OK on Bundler 2.x
  (which deprecated but accepted `--path`); fails loudly on Bundler
  4.x (which removes it). The `ruby:4.0-slim` base image ships
  Bundler 4.x, so the Docker build was broken at HEAD. Surfaced by
  `cgminer_manager`'s e2e workflow when it bumped its `monitor_ref`
  pin from `master` (v1.2.0) to `v1.3.1` for trace-id propagation
  assertions.

## [1.3.1] — 2026-04-25

### Changed
- **Widened `cgminer_api_client` constraint** from `~> 0.3.0` to
  `>= 0.3, < 0.5` so consumers like `cgminer_manager` v1.6.0 (which
  requires api_client v0.4.0 for the `on_wire:` kwarg) can pin both
  monitor and api_client without a Bundler conflict. No code change.

### Added
- **Trace-id propagation** via `X-Cgminer-Request-Id` HTTP header.
  New `CgminerMonitor::RequestId` Rack middleware extracts the
  inbound value (or generates a fresh UUID v4) and stashes it on
  `env['cgminer_monitor.request_id']`. New `http.request`
  after-filter event logs `method`, `path`, `status`, `duration_ms`,
  and `request_id`. `http.unhandled_error` also gains `request_id`.
  Response always echoes `X-Cgminer-Request-Id`. OpenAPI 3.1 spec
  documents the header on every `/v2/*` operation as optional
  inbound, plus the response-header echo via
  `components.headers.XCgminerRequestId`. Background events
  (`poll.*`, `alert.*`, `mongo.*`) deliberately don't carry
  `request_id` — they fire from the timer thread, not from HTTP
  requests.

### Changed
- **`docs/log_schema.md`** gains a Correlation subsection documenting
  `request_id` propagation across `cgminer_manager → cgminer_monitor` and
  the closure-based wiring through `cgminer_api_client`'s `on_wire`
  callback. New `cgminer.*` namespace reservation (manager-only,
  debug-level) plus `cgminer.wire` event-catalog row. Multiple existing
  event rows updated to mark `request_id` as required: `admin.auth_failed`,
  `admin.auth_misconfigured`, `http.request`, `http.500`,
  `http.unhandled_error`, `monitor.call`, `monitor.call.failed`,
  `rate_limit.exceeded` (was previously documented only for
  `admin.command` / `admin.result`). Implementations follow in upcoming
  `cgminer_monitor` and `cgminer_manager` releases — schema is a
  forward-looking contract until then.
- Test-support code (FakeCgminer, CgminerFixtures) extracted to the
  shared `cgminer_test_support` gem. `spec/support/mongo_helper.rb`
  remains repo-specific and unchanged. Spec references updated to
  `CgminerTestSupport::FakeCgminer` /
  `CgminerTestSupport::Fixtures::*`.

### Added
- **Read-side suppression of `offline` alerts during a scheduled restart**
  (`lib/cgminer_monitor/restart_schedule_client.rb`). When
  `CGMINER_MONITOR_RESTART_SCHEDULE_URL` points at `cgminer_manager`'s
  `GET /api/v1/restart_schedules.json`, AlertEvaluator skips the
  `offline` rule for any miner currently inside
  `[scheduled_minute, scheduled_minute + RESTART_WINDOW_GRACE_SECONDS)`
  UTC and emits `alert.suppressed_during_restart_window` instead.
  Window math is UTC seconds-of-day modulo 86_400 so a `23:59` schedule
  with a 5-minute grace correctly suppresses an alert at 00:02 UTC the
  following day. The fetch is fail-open: HTTP failure / malformed JSON
  / missing schedules key all yield an empty schedule map plus a single
  `restart.schedule_fetch_failed` log per failure, so monitor still
  pages on real outages even when the manager is down. Two new env
  vars: `CGMINER_MONITOR_RESTART_SCHEDULE_URL` (default unset →
  suppression disabled, offline rule fires normally) and
  `CGMINER_MONITOR_RESTART_WINDOW_GRACE_SECONDS` (default 300).
  Validated at boot — bad URL or non-positive grace fail loud rather
  than at first fetch.
- **Per-miner alerts with a webhook sink**, opt-in via
  `CGMINER_MONITOR_ALERTS_ENABLED=true`. Evaluates three rules per
  poll tick against the freshly-written `Snapshot` collection:
  `hashrate_below` (from `SUMMARY.GHS 5s`), `temperature_above`
  (max-over-devices from `DEVS[].Temperature`), and `offline`
  (seconds since last ok snapshot). Thresholds are global ENV vars;
  leaving any single threshold unset disables that rule. At least
  one threshold must be set when enabled — boot fails loudly
  otherwise rather than silently becoming a no-op. Disabled by
  default, so Prometheus + Alertmanager users carry zero new surface.
- **Stateful fire-and-resolve model.** New `alert_states` Mongo
  collection tracks per-`(miner, rule)` state via a composite string
  `_id` — no secondary index. `alert.fired` emits on a
  healthy→violating transition (including the first-ever observation);
  `alert.resolved` on violating→healthy. While a rule stays violating,
  `alert.fired` re-emits after `CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS`
  (default 300s) so consumers that missed a notification still get
  re-paged. State survives restart: a still-violating rig fires on
  the first post-restart tick (the event is new to the consumer).
- **Webhook formats: generic / slack / discord.** Generic is a stable
  JSON contract (`{event, miner, rule, severity, threshold, observed,
  unit, fired_at, monitor:{version, pid}}`). Slack reshapes to the
  legacy `attachments[]` shape (Block Kit `blocks[]` doesn't support
  the color sidebar). Discord reshapes to native `embeds[]` with a
  decimal RGB color. `alerts_webhook_format` config picks one;
  default is `generic`. Webhook client uses stdlib `Net::HTTP` only
  (no new runtime gem), one POST per fire, shared open + read
  timeout from `ALERTS_WEBHOOK_TIMEOUT_SECONDS` (default 2s). No
  retry — webhook failures log `alert.webhook_failed` and the
  evaluator + poll loop continue; the semantic event is persisted
  either way.
- **`alert.*` log namespace** reserved in `docs/log_schema.md` for
  cgminer_monitor. Six events: `alert.fired`, `alert.resolved`,
  `alert.evaluation_complete` (per-tick timing pair for
  `poll.complete`), `alert.evaluator_error` (catch-all at the Poller
  call site so evaluator bugs never kill the poll loop),
  `alert.state_write_failed` (Mongo upsert failure), and
  `alert.webhook_failed`. Four new standard keys: `rule`,
  `threshold`, `observed`, `unit`.
- Evaluator runs inside the poller thread, synchronously, **after**
  the `poll.complete` log line — preserves the completion-timestamp
  cadence the healthz stall-detection relies on. Evaluator emits its
  own `alert.evaluation_complete` with `duration_ms` for end-to-end
  timing.

### Changed
- `Server#bootstrap_mongoid!` now calls
  `CgminerMonitor::AlertState.create_indexes` alongside
  `Snapshot.create_indexes`. Only the implicit `_id` index is
  created; no secondary index.

## [1.2.0] — 2026-04-23

### Added
- **OpenAPI envelope schemas** for the four miner-snapshot endpoints
  (`/v2/miners/{miner}/{summary,stats,devices,pools}`) and the three
  graph-data endpoints (`/v2/graph_data/{hashrate,temperature,availability}`).
  Previously these 200 responses had `description:` only with no
  `content:` block; the seven endpoints now reference one of two
  reusable `components.schemas` (`SnapshotEnvelope` with `{ok, response,
  error}`; `GraphDataEnvelope` with `{fields, data}`). The inner
  `response:` on snapshot endpoints stays declared open
  (`additionalProperties: true`) — cgminer-firmware payload drift is
  not part of this envelope contract. Bumps OpenAPI `info.version`
  `"2.0.0"` → `"2.1.0"` (additive, non-breaking). New
  `spec/openapi_schema_spec.rb` pins the `$ref` wiring so a future
  refactor that silently drops a reference fails loudly.
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

### Changed
- **README `Security` section** expanded into a `Security posture`
  section with an explicit trusted-network stance, an enumeration
  of what the `/v2/*` endpoints leak in plaintext (miner list,
  per-rig telemetry, Prometheus metrics, healthz, OpenAPI/docs),
  and a reverse-proxy + TLS nginx snippet. Posture itself is
  unchanged (monitor remains auth-free by design); only the
  documentation is clearer.
- **`server.start` log entry** now emits flat scalar keys (`pid`,
  `bind`, `port`, `log_format`, `log_level`, `mongo_url`) rather
  than a nested `config:` hash. Matches `cgminer_manager`'s
  `server.start` shape and the style of every other structured-log
  emit site. Log consumers that queried `config.mongo_url` need to
  query `mongo_url` directly; `config.*` nested access no longer
  resolves. `mongo_url` remains credential-redacted.

### Added
- **`docs/log_schema.md`** — canonical structured-log schema for
  the three sibling gems, covering reserved keys, standard-key
  types, namespace reservations (which repo owns `poll.*`,
  `admin.*`, `rate_limit.*`, etc.), a full per-event catalog with
  required and optional keys, evolution rules, and grep recipes
  for log consumers. `cgminer_manager` and `cgminer_api_client`
  link here rather than duplicate the contract.

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
