# AGENTS.md — `cgminer_monitor`

Consolidated context for AI coding assistants. For end-user docs, see [`README.md`](README.md). For the 1.0 rewrite history and upgrade path from 0.x, see [`CHANGELOG.md`](CHANGELOG.md) and [`MIGRATION.md`](MIGRATION.md). For deep dives on any topic below, see [`docs/`](docs/) (start with [`docs/index.md`](docs/index.md)).

## Table of contents

- [What this is](#what-this-is)
- [Repo layout](#repo-layout) *(which files are shipped, which aren't)*
- [How the pieces fit together](#how-the-pieces-fit-together)
- [Conventions that matter when editing code](#conventions-that-matter-when-editing-code)
- [Running tests and lint](#running-tests-and-lint)
- [Adding a new HTTP endpoint](#adding-a-new-http-endpoint)
- [Adding a new extracted metric](#adding-a-new-extracted-metric)
- [Ruby and Mongo version support](#ruby-and-mongo-version-support)
- [Gotchas worth knowing up front](#gotchas-worth-knowing-up-front)
- [Release process](#release-process)
- [Where to look for deeper context](#where-to-look-for-deeper-context)

---

## What this is

<!-- metadata: overview, stack, purpose -->

A standalone Ruby daemon that polls [cgminer](https://github.com/ckolivas/cgminer) instances, stores device/pool/summary/stats data in MongoDB, and serves a read-only HTTP API. **Not** a Rails engine anymore — the 1.0 rewrite (April 2026) made it a plain foreground process run under a supervisor (systemd, Docker, launchd).

**Stack:** Ruby 3.2+ (gemspec floor), MongoDB 5.0+ (time-series collections). Runtime deps: `cgminer_api_client ~> 0.3.0`, `mongoid ~> 9.0`, `sinatra >= 4.0`, `puma >= 6.0`, `rack-cors ~> 2.0`. Dev deps: `rspec`, `rubocop` (+ `-rake`, `-rspec`), `rack-test`, `rake`, `simplecov`.

**Footprint:** ~1050 SLOC in `lib/`, ~2250 SLOC in `spec/`. Small, well-tested.

**Execution model:** CLI subcommand `cgminer_monitor run` starts one process with two threads — Poller (cgminer → Mongo) and Puma (HTTP out). SIGTERM/SIGINT → graceful shutdown with timeout, exit 0. Config validation failure → exit 78. Anything else bad → exit 1.

## Repo layout

<!-- metadata: directory-structure, file-organization -->

```
├── bin/cgminer_monitor             # CLI: run / migrate / doctor / version (packaged)
├── lib/cgminer_monitor.rb          # require graph only
├── lib/cgminer_monitor/
│   ├── config.rb                   # Data.define Config from env, validation, redaction
│   ├── errors.rb                   # Error < StandardError, ConfigError
│   ├── logger.rb                   # Structured JSON/text logger (module singleton, thread-safe)
│   ├── sample.rb                   # Mongoid: samples (time-series, ts/meta/v)
│   ├── sample_query.rb             # Read-side: hashrate, temperature, availability series
│   ├── snapshot.rb                 # Mongoid: latest_snapshot (regular, upserted per poll)
│   ├── snapshot_query.rb           # Read-side: for_miner, miners, last_poll_at
│   ├── poller.rb                   # Polling loop, sample extraction, bulk writes to Mongo
│   ├── server.rb                   # Orchestrator: signals, Mongoid, Poller, Puma, shutdown
│   ├── http_app.rb                 # Sinatra app: /v2/*, /metrics, /openapi.yml, /docs
│   ├── openapi.yml                 # OpenAPI 3.1 (packaged, served at /openapi.yml, CI-guarded)
│   └── version.rb                  # VERSION = "1.0.0"
├── spec/                           # RSpec unit + integration (NOT packaged)
│   ├── cgminer_monitor/            # Unit specs, one per lib/ file
│   ├── integration/                # full_pipeline, cli, healthz
│   ├── openapi_consistency_spec.rb # route ↔ openapi.yml parity guard
│   └── support/                    # FakeCgminer, CgminerFixtures, mongo_helper
├── config/miners.yml.example       # NOT packaged (gemspec omits it deliberately)
├── docs/                           # AI-assistant knowledge base (this is where you're reading from)
├── .github/workflows/ci.yml        # lint + test matrix + integration + openapi-check jobs
├── .rubocop.yml                    # TargetRubyVersion 3.2; Metrics/* cops largely off
├── .rspec / .ruby-version
├── Rakefile                        # default: [spec, rubocop]
├── Dockerfile                      # Multi-stage, ruby:3.4-slim base
├── docker-compose.yml              # mongo + cgminer_monitor + optional fake_cgminer
├── Gemfile                         # ostruct conditional pin for Ruby >= 3.5
├── cgminer_monitor.gemspec
├── CHANGELOG.md                    # Keep-a-Changelog; 1.0.0 notes
├── MIGRATION.md                    # 0.x → 1.0 upgrade guide for consumers
├── README.md
└── LICENSE.txt                     # MIT
```

**What's packaged in the gem** (gemspec `spec.files`): `lib/**/*.rb`, `lib/**/*.yml` (the OpenAPI spec), `bin/*`, `README.md`, `LICENSE.txt`, `CHANGELOG.md`, `cgminer_monitor.gemspec`. Everything else (specs, configs, Docker, MIGRATION, `docs/`, CI workflows) is dev-only. Notably `config/miners.yml.example` is NOT packaged — the docker-compose expects the operator to mount their own.

## How the pieces fit together

<!-- metadata: architecture, dataflow -->

```
bin/cgminer_monitor run
      │
      ▼
   Server ──install signal handlers──► @stop: Queue
      │
      ├──configure Mongoid──► Mongo
      ├──bootstrap samples + snapshot collections
      │
      ├──spawn Poller thread ──► cgminer_api_client::MinerPool ──TCP──► cgminer instances
      │                              │
      │                              └──► Sample.insert_many + Snapshot.bulk_write ──► Mongo
      │
      └──spawn Puma thread ──► HttpApp ──► SampleQuery / SnapshotQuery ──► Mongo

   SIGTERM/SIGINT ──► push to @stop ──► poller.stop + launcher.stop ──► exit 0
```

**Key structural facts:**

1. **Two threads, one process, one `@stop` Queue.** Poller runs a `while !stopped` loop; Puma runs until `launcher.stop`. Main thread blocks on `@stop.pop` until a signal handler (or a Puma crash) pushes something.
2. **`HttpApp` has class-level state** set by `Server` at boot: `.poller`, `.started_at`, `.configured_miners_cache`. Tests must call `HttpApp.reset_configured_miners!` between examples.
3. **`Config` is immutable.** `Data.define`. Validated once in `Config.from_env`. There's no hot reload. Config changes require a restart.
4. **Mongoid is configured programmatically** from `CGMINER_MONITOR_MONGO_URL`. No `config/mongoid.yml` exists. This was explicit in the 1.0 rewrite.
5. **`Sample.store_in` is called at runtime**, not as a class macro, because the `expire_after` depends on `Config#retention_seconds`. `Sample.create_collection` is called explicitly so the collection is actually time-series (not a regular lazy-created one).
6. **Poller bypasses `CgminerApiClient::MinerPool.new`** because that constructor hard-codes `'config/miners.yml'` relative to CWD — which doesn't honor `CGMINER_MONITOR_MINERS_FILE`. Uses `MinerPool.allocate` + manual `.miners=`.
7. **OpenAPI is source of truth.** `spec/openapi_consistency_spec.rb` walks `HttpApp`'s routes and checks against `lib/cgminer_monitor/openapi.yml`. Adding/removing routes requires updating the YAML in the same commit.

## Conventions that matter when editing code

<!-- metadata: coding-style, conventions, best-practices -->

### Ruby style

- **Every file starts with `# frozen_string_literal: true`.** New files too.
- **`Data.define` for immutable value objects**, not `Struct` or custom classes. See `Config`.
- **Explicit `StandardError` in bare rescues** (`rescue StandardError => e`). The one exception is `rescue Exception` inside the Puma thread crash handler in `Server#run` — it's there on purpose, with a RuboCop disable comment.
- **Structured logging everywhere.** Use `Logger.info(event: '...', ...)` with keyword arguments. Every event has an `event:` name for grep-ability. No class in `lib/` uses `warn`, `puts`, or `$stderr` directly. The only direct `warn` calls are in `bin/cgminer_monitor` for top-level error messages.
- **`YAML.safe_load_file`**, not `YAML.load_file`.
- **Don't mutate `Config` at runtime.** If you find yourself wanting to, that's the wrong tool — add an env var, bump the supervisor to restart.

### RuboCop

- `.rubocop.yml` disables most `Metrics/*` cops and most `RSpec/*` style cops. Short parameter names (`ok`, `ts`, `v`) are allowed via `Naming/MethodParameterName` because they're idiomatic for Mongo.
- Correctness cops (`RSpec/RepeatedExample`, `RSpec/LeakyConstantDeclaration`, etc.) stay on.
- `bundle exec rake` runs specs + rubocop as the default task.

### Commit style

- **One commit per logical step.** Multi-step changes should land with one commit per step, and `bundle exec rake` should pass before each commit.
- Imperative mood ("Add X", "Fix Y"), kept tight. Look at recent `git log` for the project's voice.

### Error handling

- New errors should subclass `CgminerMonitor::Error` (or `ConfigError`, which is the only currently-populated child). Don't add a sibling class unless you have a raise site and tests ready in the same change.
- **Rescue narrowly.** `Poller#poll_once` catches `Mongo::Error` separately from `StandardError` so Mongo outages show up as a distinct log event. Follow that pattern.
- **Don't silently swallow.** The Poller's `rescue StandardError => e; increment_failed; Logger.error(...)` looks like a catch-all, but it's *logged* with backtrace. If you add a new rescue, log it too.
- `Server#run`'s top-level `rescue StandardError` returns exit code 1. `ConfigError` caught in `bin/cgminer_monitor` returns exit 78. Don't route new errors through the generic path if they have a specific treatment.

### Testing

- **Unit specs live at `spec/cgminer_monitor/**`**, one file per `lib/` file. Integration specs at `spec/integration/`.
- **Integration specs use a real MongoDB** and `FakeCgminer` (shared with `cgminer_api_client` via `spec/support/fake_cgminer.rb`). Mongo comes from `CGMINER_MONITOR_MONGO_URL` env; in CI it's a service container, locally it's `docker run mongo:7`.
- **HTTP specs use `Rack::Test::Methods`** against `HttpApp` directly — no Puma spin-up.
- **CLI integration specs spawn the real binary** via `Open3.capture3` and assert on exit codes and stream contents.
- **`spec/openapi_consistency_spec.rb`** is a CI guard. Keep it passing.
- **`config.order = :random`** — specs must be order-independent.
- **`mocks.verify_partial_doubles = true`** — doubles must match real method signatures.
- Warnings are on in `.rspec`. Keep the suite warning-clean.
- Between specs that touch `HttpApp.configured_miners_cache`, call `HttpApp.reset_configured_miners!`.

## Running tests and lint

<!-- metadata: testing, local-dev, commands -->

```sh
# Prereq: MongoDB available (for integration specs and anything that touches Mongoid)
docker run -d --name cgminer-mongo-test -p 27017:27017 mongo:7

bundle install
bundle exec rake                                       # spec + rubocop (default)
bundle exec rspec                                      # all specs
bundle exec rspec spec/cgminer_monitor                 # unit only
bundle exec rspec spec/integration                     # integration only
bundle exec rspec spec/openapi_consistency_spec.rb     # openapi parity only
bundle exec rspec path/to/spec.rb:123                  # single example
bundle exec rubocop                                    # lint only
bundle exec rubocop -A                                 # lint + auto-correct
```

**Coverage** is always on (SimpleCov in `spec_helper.rb`). Reports in `coverage/` — `.gitignore`d.

**Manual sandbox** without real miners:

```sh
# With docker-compose
docker-compose --profile testing up   # Mongo + cgminer_monitor + FakeCgminer

# Or manually
docker run -d -p 27017:27017 mongo:7
cp config/miners.yml.example config/miners.yml  # then edit for your FakeCgminer port
bundle exec bin/cgminer_monitor doctor          # check connectivity
bundle exec bin/cgminer_monitor run
```

## Adding a new HTTP endpoint

<!-- metadata: extending, how-to -->

1. **Add the Sinatra route** in `lib/cgminer_monitor/http_app.rb`:
   ```ruby
   get '/v2/my_new_thing' do
     # ... read from SampleQuery or SnapshotQuery (or add a new query method there)
     JSON.generate({ ... })
   end
   ```
2. **Update the OpenAPI spec** at `lib/cgminer_monitor/openapi.yml`. Add a `paths: /v2/my_new_thing:` entry with request params, response shape, and status codes. Required — `spec/openapi_consistency_spec.rb` will fail CI otherwise.
3. **Write a unit spec** in `spec/cgminer_monitor/http_app_spec.rb` using `Rack::Test`. Cover: happy path, error cases, edge cases on query parameters.
4. **If the endpoint touches new data**, add a query method in `SampleQuery` or `SnapshotQuery` (or a new sibling module) rather than querying from `HttpApp` directly. Keep HTTP routing separate from storage access.
5. **Update the README's endpoints table** if this is user-facing.
6. **Don't add auth.** The app is designed for trusted networks; adding auth piecemeal would be worse than having it clearly in scope.

## Adding a new extracted metric

<!-- metadata: extending, how-to -->

`Poller#extract_samples` is the one place that knows how to turn a cgminer response into sample rows.

1. **No code change needed** if the new metric is already a numeric field on a cgminer command's response. `extract_samples` walks every field via `response[COMMAND_KEY].each` and emits a sample for anything that passes `to_numeric`. The new field will just start showing up in `samples` on the next poll.
2. **For derived / synthetic metrics** (like the existing `poll.ok` and `poll.duration_ms`), add them in `Poller#append_synthetic_samples`.
3. **For per-metric query helpers** (like `SampleQuery.hashrate`), add a method to `SampleQuery` that scopes by `meta.metric`. Update the relevant HTTP endpoint.
4. **If the metric becomes part of Prometheus exposition**, update `HttpApp#build_prometheus_metrics` and add `# HELP` / `# TYPE` lines.
5. **Tests:** exercise the new extraction via an integration spec using `FakeCgminer` fixtures, not just unit-level mocks.

## Ruby and Mongo version support

<!-- metadata: runtime, compatibility -->

- **Ruby minimum: 3.2.** Gemspec enforces. CI matrix: 3.2/3.3/3.4 required, 4.0 and head best-effort.
- **Mongo minimum: 5.0** (required for time-series collections). CI uses 6.0 and 7.0 because 5.0 isn't available as a GitHub Actions service. The 5.0 floor is asserted but not tested in CI directly.
- **Local dev:** `.ruby-version` pins a specific Ruby (currently 3.4-ish).

**Sharp edges:**
- Ruby 3.4 deprecates some `ostruct` usage that Mongoid 9 still does. The CLI integration spec tolerates the deprecation warnings on stderr.
- Ruby 4.0 removed `ostruct` from default gems entirely — `Gemfile` conditionally pins `gem 'ostruct'` when `RUBY_VERSION >= '3.5'` as a compatibility shim.
- Mongoid 9 caps `bson < 6`. When bson 6 ships, we can't upgrade until Mongoid 10.
- `Data.define` requires Ruby 3.2+. Used for `Config`.
- Time-series collections require Mongo 5.0+. `Sample.create_collection` with `collection_options: time_series: {...}` will fail on older Mongo.

## Gotchas worth knowing up front

<!-- metadata: caveats, surprises -->

These are real past-incident-shaped corners. Keep them in mind before "cleaning up" related code:

1. **Signal handlers must be installed before `Puma::Launcher.run`, then reinstalled after.** Puma's `setup_signals` synchronously overwrites process-wide handlers. `Server#install_signal_handlers` runs first (pre-Puma). Then Puma starts in its own thread. Then `Server#reinstall_signal_handlers` waits 50ms and reinstalls. The `sleep 0.05` is a heuristic handoff, not a correctness guarantee — if you change how Puma starts, re-verify SIGTERM still routes through the `@stop` queue.

2. **`raise_exception_on_sigterm false`** in `Server#build_puma_launcher` is load-bearing. By default Puma raises `SignalException` on SIGTERM, which would bubble out of the Puma thread and miss our `@stop`-queue path. Don't remove it.

3. **`Poller#build_miner_pool` uses `MinerPool.allocate` + `.miners=`.** That's because `CgminerApiClient::MinerPool.new` hard-codes `'config/miners.yml'` relative to CWD. If `cgminer_api_client` ever grows a constructor that accepts a path, we can delete the `.allocate` ceremony. Until then, keep it.

4. **`Sample` doesn't have `store_in` as a class macro.** It's called at runtime from `Server#bootstrap_mongoid!` (and from `cgminer_monitor migrate`) because the `expire_after` TTL depends on runtime config. `create_collection` is also called explicitly because Mongoid's lazy-create would make a regular collection, not a time-series one. Don't move the `store_in` back to class-load time.

5. **`HttpApp` has class-level state set by `Server` at boot.** If you add new state, add a `reset_*!` helper and call it in test setup. If you try to move it to instance state, you'll have to invent a way to get a reference to the current instance into Sinatra's class-level route blocks, which is the bad old dance.

6. **`config/miners.yml` path is configurable via env var**, but the *default* is `'config/miners.yml'` which is CWD-relative. If you run `cgminer_monitor run` from a directory without a `config/` subdir, you need to set `CGMINER_MONITOR_MINERS_FILE` to an absolute path.

7. **`Mongo::Error` from `insert_many`/`bulk_write` is logged but not re-raised** in `Poller#poll_once`. So a mid-poll Mongo outage leaves the process running but with `polls_failed` climbing. This is intentional — the supervisor model owns restarts, and a transient Mongo blip shouldn't blow up the process. But it means `/healthz` → `degraded` is how you see it, not a process crash.

8. **Out-of-band git changes are normal.** Don't treat surprising git state (uncommitted changes you didn't make, a new branch you didn't create) as a tool malfunction — the maintainer works outside the assistant session.

## Release process

<!-- metadata: release, publishing -->

Not automated. On a clean `master`:

```sh
bundle exec rake                                  # must pass clean
# bump VERSION in lib/cgminer_monitor/version.rb
# update CHANGELOG.md under a new version section (Keep-a-Changelog format)
git commit -am "Release vX.Y.Z"
gem build cgminer_monitor.gemspec                 # produces cgminer_monitor-X.Y.Z.gem
gem push cgminer_monitor-X.Y.Z.gem                # requires 2FA (rubygems_mfa_required=true)
git tag vX.Y.Z
git push origin master vX.Y.Z
```

Container images (Docker Hub / GHCR) are not currently pushed by CI. If that happens later, it'd be a separate workflow triggered on tag push.

## Where to look for deeper context

<!-- metadata: doc-navigation -->

| Question | File |
|---|---|
| How do the classes relate architecturally? Why two threads? Why this signal dance? | [`docs/architecture.md`](docs/architecture.md) |
| What does each class do? | [`docs/components.md`](docs/components.md) |
| What's the public method signature for X? HTTP endpoint Y? env var Z? | [`docs/interfaces.md`](docs/interfaces.md) |
| What's in a `Sample`? What's in `latest_snapshot`? What errors can be raised? | [`docs/data_models.md`](docs/data_models.md) |
| How does a poll cycle flow? How does startup/shutdown work? Release process? | [`docs/workflows.md`](docs/workflows.md) |
| Runtime deps? Why Mongo 5+? CI matrix? | [`docs/dependencies.md`](docs/dependencies.md) |
| Known doc/code drift, caveats, cleanup recommendations | [`docs/review_notes.md`](docs/review_notes.md) |
| Full knowledge-base index | [`docs/index.md`](docs/index.md) |
| User-facing docs | [`README.md`](README.md) |
| Release history and 0.x → 1.0 migration guide | [`CHANGELOG.md`](CHANGELOG.md), [`MIGRATION.md`](MIGRATION.md) |
