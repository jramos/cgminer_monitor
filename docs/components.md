# Components

Every major component lives in a single file under `lib/cgminer_monitor/`. The composition is flat: no service locator, no factories, no DI container. Components either are immutable value objects (`Config`), Mongoid models (`Sample`, `Snapshot`), module-singletons (`Logger`, `SampleQuery`, `SnapshotQuery`), or plain classes owning one concern (`Poller`, `Server`, `HttpApp`).

## Component map

```mermaid
graph LR
    subgraph cgminer_monitor_rb["cgminer_monitor.rb"]
        Mod[module CgminerMonitor]
    end
    subgraph errors_rb["errors.rb"]
        ErrClasses[Error hierarchy]
    end
    subgraph version_rb["version.rb"]
        Ver[VERSION]
    end
    subgraph config_rb["config.rb"]
        Cfg[Config]
    end
    subgraph logger_rb["logger.rb"]
        Log[Logger module singleton]
    end
    subgraph sample_rb["sample.rb"]
        Smp[Sample]
    end
    subgraph snapshot_rb["snapshot.rb"]
        Snp[Snapshot]
    end
    subgraph sample_query_rb["sample_query.rb"]
        SmpQ[SampleQuery]
    end
    subgraph snapshot_query_rb["snapshot_query.rb"]
        SnpQ[SnapshotQuery]
    end
    subgraph poller_rb["poller.rb"]
        Pol[Poller]
    end
    subgraph server_rb["server.rb"]
        Srv[Server]
    end
    subgraph http_app_rb["http_app.rb"]
        App[HttpApp]
    end

    Srv -->|owns| Pol
    Srv -->|HttpApp.set :poller/started_at/configured_miners| App
    Pol -->|writes| Smp
    Pol -->|writes| Snp
    App -->|reads via| SmpQ
    App -->|reads via| SnpQ
    SmpQ -->|queries| Smp
    SnpQ -->|queries| Snp
    Pol -.logs.-> Log
    Srv -.logs.-> Log
    App -.logs.-> Log
    Pol -->|raises| ErrClasses
    Cfg -->|raises| ErrClasses
    Cfg -.reads env-.-> Srv
```

## Component list

### `CgminerMonitor` (module)
**File:** `lib/cgminer_monitor.rb`

Top-level namespace. The file is only `require` statements for the other files plus an empty `module CgminerMonitor; end`. Loads, in order: `cgminer_api_client`, `mongoid`, then the gem's own modules in dependency order.

### `CgminerMonitor::Error` and siblings
**File:** `lib/cgminer_monitor/errors.rb`

Two exception classes:
- `Error < StandardError` — gem base. Catch this to handle everything gem-specific.
- `ConfigError < Error` — raised by `Config#validate!` and from `bin/cgminer_monitor` when env vars fail parsing. Mapped to exit 78 at the CLI boundary.

Mongo driver errors (`Mongo::Error`) and cgminer API errors (`CgminerApiClient::ConnectionError`, `CgminerApiClient::ApiError`) are caught at their respective boundaries and either logged or attached to failed snapshot docs rather than rewrapped as gem-specific errors.

### `CgminerMonitor::Config` (`Data.define`)
**File:** `lib/cgminer_monitor/config.rb`

Immutable 14-field value object built from ENV. Fields: `interval`, `retention_seconds`, `mongo_url`, `http_host`, `http_port`, `http_min_threads`, `http_max_threads`, `miners_file`, `log_format`, `log_level`, `cors_origins`, `shutdown_timeout`, `healthz_stale_multiplier`, `healthz_startup_grace_seconds`.

Public surface:
- `Config.from_env(env = ENV)` — build + validate in one call. Raises `ConfigError` on bad values.
- `Config.current` — memoized `from_env` result for code paths that want a global handle (primarily `HttpApp`). `Config.reset!` clears the memo (tests only).
- `#validate!` — runs sanity checks: `interval > 0`, `log_format ∈ {json, text}`, `miners_file` exists, `log_level ∈ {debug, info, warn, error}`.
- `#public_attrs` — `to_h` with the mongo URL redacted (`mongodb://user:pass@host` → `mongodb://[REDACTED]@host`). Used for logging and `doctor` output.

Any constructor field that fails parsing surfaces as a `ConfigError` at boot time, which the CLI translates into exit `78` (`EX_CONFIG`).

### `CgminerMonitor::Logger` (module singleton)
**File:** `lib/cgminer_monitor/logger.rb`

Thread-safe module-level structured logger. Writes to `$stdout` by default (overridable via `Logger.output=` for tests).

Public surface:
- `Logger.info(**fields)`, `.warn`, `.error`, `.debug` — keyword-only. Every call gets `ts` (ISO-8601 with millis) and `level` automatically merged in. The convention is that every event has an `event:` key naming it (`'poll.complete'`, `'server.stopping'`, `'healthz.mongo_unreachable'`).
- `Logger.format=` — `"json"` (default) writes one JSON object per line; `"text"` writes `ts LEVEL event k=v k=v` for humans.
- `Logger.level=` — `"debug"`, `"info"`, `"warn"`, `"error"`. Lines below the configured level are dropped.

Locking is via an internal `Mutex`, so concurrent writes from the Poller thread and the Puma thread don't interleave within a single line.

### `CgminerMonitor::Sample` (Mongoid document)
**File:** `lib/cgminer_monitor/sample.rb`

Mongoid model for the `samples` MongoDB time-series collection. Three fields: `ts` (Time), `meta` (Hash with `miner`, `command`, `sub`, `metric`), and `v` (Float).

Crucially, `store_in` is **not** called as a class macro here — it's invoked programmatically by `Server#bootstrap_mongoid!` (or by `cgminer_monitor migrate`) with runtime collection options (the `expire_after` TTL depends on `Config#retention_seconds`, which doesn't exist at class-load time). This is also why `create_collection` has to be called explicitly: Mongoid's lazy-create would make a regular collection instead of a time-series one.

### `CgminerMonitor::Snapshot` (Mongoid document)
**File:** `lib/cgminer_monitor/snapshot.rb`

Mongoid model for the `latest_snapshot` regular collection. Fields: `miner` (String), `command` (String), `fetched_at` (Time), `ok` (Boolean), `response` (Hash), `error` (String).

Two indexes:
- `{miner: 1, command: 1}` **unique** — enforces one doc per miner+command. Every poll upserts against this compound key.
- `{fetched_at: 1}` — supports "most recently polled" queries for healthz and metrics.

`store_in collection: "latest_snapshot"` is a class macro here (not parameterized like `Sample`), since this is a plain collection.

### `CgminerMonitor::SampleQuery` (module)
**File:** `lib/cgminer_monitor/sample_query.rb`

Read-side module. Three public methods:
- `hashrate(miner: nil, since: nil, until_: nil)` — returns `[[ts, ghs_5s, ghs_av, device_hardware_pct, device_rejected_pct, pool_rejected_pct, pool_stale_pct], ...]`. Pool-wide when `miner` is nil (aggregated via sum or mean depending on the metric).
- `temperature(miner: nil, since: nil, until_: nil)` — returns `[[ts, min, avg, max], ...]` per ts from `devs`/`stats` samples whose metric name matches `/^temp/`.
- `availability(miner: nil, since: nil, until_: nil)` — per-miner: `[[ts, 0|1], ...]`. Pool-wide: `[[ts, available_count, configured_count], ...]`.

Defaults the time range to the last hour when `since`/`until_` are nil.

### `CgminerMonitor::SnapshotQuery` (module)
**File:** `lib/cgminer_monitor/snapshot_query.rb`

Read-side module. Three public methods:
- `for_miner(miner:, command:)` — returns the single `Snapshot` matching the compound key, or nil.
- `miners` — runs a Mongo aggregation pipeline to collapse snapshots by miner, returning `[{miner:, fetched_at:, ok:}, ...]` where `ok` is "any command succeeded in the most recent poll."
- `last_poll_at(miner:)` — the most recent `fetched_at` across all commands for that miner.

### `CgminerMonitor::Poller`
**File:** `lib/cgminer_monitor/poller.rb`

The write side. Three responsibilities: orchestrate a poll cycle, extract samples from cgminer responses, and persist to Mongo.

Public surface:
- `initialize(config, miner_pool: nil)` — `miner_pool` injectable for tests; otherwise built from `config.miners_file`.
- `poll_once` — one full iteration: query every miner for each of `[summary, devs, pools, stats]`, build sample rows + snapshot upserts, write them in bulk, log `'poll.complete'`. Catches `Mongo::Error` and general `StandardError` so one failure doesn't kill the thread.
- `run_until_stopped(_stop_channel)` — loop invoking `poll_once`, sleeping the remaining interval via the interruptible condvar.
- `stop` — signals the condvar so the sleep exits immediately; sets `@stopped = true`.
- `stopped?`, `polls_ok`, `polls_failed` — state introspection for `HttpApp`.

Private surface worth noting:
- `extract_samples(miner_id, command, response, ts)` — the leaf function that knows cgminer's response shape. Extend here to record a new metric.
- `normalize_metric(field)` — lowercases, replaces spaces with underscores, maps `%` to `_pct`. Turns `"Pool Rejected%"` into `pool_rejected_pct`.
- `build_miner_pool(miners_file)` — the `CgminerApiClient::MinerPool.allocate` + manual `.miners=` dance that honors a configurable miners path.

### `CgminerMonitor::Server`
**File:** `lib/cgminer_monitor/server.rb`

Orchestrator. `Server#run` is the `cgminer_monitor run` entry point and returns an exit code.

Responsibilities:
- Install SIGTERM/SIGINT handlers **before** Puma starts (and reinstall after, see `architecture.md`).
- Configure Mongoid from `config.mongo_url`.
- `validate_startup!` — verify `miners.yml` parses non-empty and Mongo is reachable (raises `ConfigError` on empty, `Mongo::Error` on unreachable).
- `bootstrap_mongoid!` — programmatic `store_in` + `create_collection` for `Sample`; `create_indexes` for `Snapshot`.
- Wire up `HttpApp` Sinatra settings (`settings.poller`, `settings.started_at`, `settings.configured_miners`) for health-check and metrics access via `HttpApp.set :key, value`.
- Spawn Poller and Puma threads; block on `@stop.pop`.
- On signal: stop poller, `join` with shutdown timeout, stop launcher, `join` again, exit 0.
- On `StandardError` in `run` body: log, exit 1. `ConfigError` from `validate_startup!` surfaces here — CLI translates any `ConfigError` to exit 78.

### `CgminerMonitor::HttpApp` (Sinatra::Base)
**File:** `lib/cgminer_monitor/http_app.rb`

The read side. Sinatra app mounted under Puma. All routes under `/v2/*`, plus `/openapi.yml` and `/docs`.

App state lives in Sinatra settings, written by `Server#run` before Puma accepts its first request:
- `settings.poller` — reference to the running `Poller` instance for metrics counters (`polls_ok`, `polls_failed`).
- `settings.started_at` — UTC Time, uptime source for `/healthz`.
- `settings.configured_miners` — eager-built frozen list of `[miner_id, host, port]` from `Config.current.miners_file`. Read by `/miners`, used to validate `:miner` path params. Defaults to `nil`; the `configured_miners` helper raises if read before Server populates it.
- `HttpApp.parse_miners_file(path)` — lift-out of the old lazy body; used by `Server#run` and `configure_for_test!` to build the list.
- `HttpApp.configure_for_test!(miners:, poller:, started_at:)` — spec-harness helper that sets all three settings in one call.

Uses `Rack::Cors` middleware configured from `Config.current.cors_origins`. `show_exceptions` and `dump_errors` are off; a generic `error do` handler logs unhandled exceptions via `Logger.error` and returns `{"error": "internal"}` with HTTP 500. A `not_found` handler returns `{"error": "not found"}` with 404.

Routes dispatch into `SampleQuery`/`SnapshotQuery` for everything read-shaped; the Prometheus endpoint builds its output from `Snapshot` queries directly plus `poller`'s counters.

### OpenAPI spec file
**File:** `lib/cgminer_monitor/openapi.yml`

OpenAPI 3.1 document. Packaged in the gem (the gemspec includes `lib/**/*.yml`), served at `/openapi.yml`, and asserted against `HttpApp`'s registered routes by `spec/openapi_consistency_spec.rb`. Adding or removing a route requires updating this file in the same commit.

## CLI

### `bin/cgminer_monitor`
**File:** `bin/cgminer_monitor`

Subcommand dispatcher. Four real commands and four deprecated shims from the 0.x Daemon-based world:

| Subcommand | Does |
|---|---|
| `run` | `Config.from_env` → `Server.new(config).run` → exit with its return code |
| `migrate` | Configure Mongoid, `Sample.store_in`, `Sample.create_collection`, `Snapshot.create_indexes`. Idempotent. |
| `doctor` | Print config, test Mongo connectivity, test each miner's `version` command. Diagnostic only. |
| `version` / `-v` / `--version` | Print `cgminer_monitor <VERSION>` |
| `start` | Deprecated: prints "did you mean 'run'?" and exits 64 |
| `restart` | Deprecated: "did you mean 'run'?" exit 64 |
| `status` | Deprecated: "did you mean 'doctor'?" exit 64 |
| `stop` | Deprecated: "Process management is now handled by your supervisor." exit 64 |
| any other | exits 64 with a usage hint |
| (no argument) | prints usage block and exits 64 |

Exit codes:
- `0` — `run` completed cleanly.
- `1` — `run` crashed, or `migrate` hit a Mongo error.
- `64` — unknown command (`EX_USAGE`).
- `78` — `ConfigError` at startup (`EX_CONFIG`).

## Test-only components (not packaged in the gem)

### `FakeCgminer`
**File:** `spec/support/fake_cgminer.rb`

Identical to the one in `cgminer_api_client` — an in-process TCP server that accepts a JSON request, looks up the command name in a fixtures hash, writes a canned response, and closes the socket. Used by `spec/integration/full_pipeline_spec.rb` to exercise the whole pipeline without real miners.

### `CgminerFixtures`
**File:** `spec/support/cgminer_fixtures.rb`

Also identical to api_client's. Canned cgminer wire-format JSON responses keyed by command name.

### `mongo_helper.rb`
**File:** `spec/support/mongo_helper.rb`

Configures Mongoid for the test database (reads `CGMINER_MONITOR_MONGO_URL` or defaults to `mongodb://localhost:27017/cgminer_monitor_test`), clears collections between examples, ensures the `samples` time-series collection exists before tests that need it.
