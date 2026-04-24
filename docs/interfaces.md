# Interfaces

`cgminer_monitor` has four distinct surfaces:
1. The **CLI** (`cgminer_monitor` binary).
2. The **environment-variable config**.
3. The **`miners.yml`** file.
4. The **HTTP API** (including Prometheus and OpenAPI/Swagger endpoints).

And it consumes two external interfaces:
5. **`cgminer_api_client`** (Ruby library) — for talking to cgminer.
6. **MongoDB** — for persistence.

## 1. CLI

### Binary

```
cgminer_monitor <command> [options]
```

### Subcommands

| Command | Purpose | Exit codes |
|---|---|---|
| `run` | Start the service in the foreground. Blocks until SIGTERM/SIGINT. | `0` clean shutdown, `1` crash, `78` config error |
| `migrate` | Create MongoDB collections and indexes. Idempotent — safe to run on every deploy. | `0` ok, `1` Mongo error, `78` config error |
| `doctor` | Print config (with mongo URL redacted), test Mongo connectivity, ping every configured miner. Read-only. | always `0` |
| `version` / `-v` / `--version` | Print `cgminer_monitor <VERSION>` | `0` |
| `start` / `restart` / `status` / `stop` | Deprecated shims from the 0.x Daemon-based CLI. Print a "did you mean…" hint. | `64` |
| unknown or missing | Print a usage block. | `64` (`EX_USAGE`) |

Exit code semantics follow [`sysexits(3)`](https://man.openbsd.org/sysexits.3):
- `0` — success.
- `1` — unspecified failure (server crash, unexpected exception).
- `64` (`EX_USAGE`) — invocation error.
- `78` (`EX_CONFIG`) — configuration validation failed.

### Output streams

**stdout:**
- `run`: structured log lines (one per event). Format controlled by `CGMINER_MONITOR_LOG_FORMAT` (`json` or `text`).
- `migrate`: log line for `migrate.complete`, then `migrate: done`.
- `doctor`: human-readable diagnostics (headers, indented key/value pairs, `OK` / `FAILED` per check).
- `version`: single line.

**stderr:**
- Usage hints and deprecated-subcommand warnings.
- Unexpected configuration errors from `run`/`migrate`: `Configuration error: <message>`.
- Unexpected Mongo errors from `migrate`: `MongoDB error during migration: <ClassName>: <message>`.

Library-level code never writes directly to stderr — everything flows through `CgminerMonitor::Logger`, which writes to stdout. The only direct `warn` calls are in `bin/cgminer_monitor` itself, gated on the top-level error type.

### Environment variables consumed by the CLI

Backtrace logging on `server.crash` is unconditional — the `Exception#backtrace` array is always included in the error log entry. There is no runtime toggle for it.

## 2. Environment-variable config

All knobs are `ENV` reads at boot via `Config.from_env`. Defaults in parentheses.

| Variable | Default | Purpose |
|---|---|---|
| `CGMINER_MONITOR_INTERVAL` | `60` | Seconds between poll cycles. Must be > 0. |
| `CGMINER_MONITOR_RETENTION_SECONDS` | `2592000` (30 days) | Time-series data TTL. Applied via Mongo's `expire_after` at `create_collection` time. |
| `CGMINER_MONITOR_MONGO_URL` | `mongodb://localhost:27017/cgminer_monitor` | Mongoid client URI. Secrets in this string are redacted in logs. |
| `CGMINER_MONITOR_HTTP_HOST` | `127.0.0.1` | Puma bind address. Set to `0.0.0.0` inside Docker. |
| `CGMINER_MONITOR_HTTP_PORT` | `9292` | Puma bind port. |
| `CGMINER_MONITOR_HTTP_MIN_THREADS` | `1` | Puma min threads. |
| `CGMINER_MONITOR_HTTP_MAX_THREADS` | `5` | Puma max threads. |
| `CGMINER_MONITOR_MINERS_FILE` | `config/miners.yml` | Path to miners YAML. |
| `CGMINER_MONITOR_LOG_FORMAT` | `json` | `json` or `text`. |
| `CGMINER_MONITOR_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error`. |
| `CGMINER_MONITOR_CORS_ORIGINS` | `*` | Comma-separated list for `Rack::Cors`, or `*` for permissive. |
| `CGMINER_MONITOR_SHUTDOWN_TIMEOUT` | `10` | Seconds to wait for each of Poller and Puma to stop during graceful shutdown. |
| `CGMINER_MONITOR_HEALTHZ_STALE_MULTIPLIER` | `2` | Stale threshold = `interval * multiplier` seconds since last poll before `/healthz` returns `degraded`. |
| `CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE` | `60` | Seconds after boot during which a missing poll still reports `starting` rather than `degraded`. |
| `CGMINER_MONITOR_ALERTS_ENABLED` | `false` | Master switch for the per-miner alerts feature. When `false`, the evaluator early-returns and zero alert surface is exercised. Accepts `1`/`true`/`yes`/`on` (and their negatives), case-insensitive. |
| `CGMINER_MONITOR_ALERTS_WEBHOOK_URL` | *(none)* | Required when `ALERTS_ENABLED=true`. Must be `http(s)://<host>[:port]/…` with a non-empty host. Validated at boot. |
| `CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT` | `generic` | Webhook body shape. One of `generic` (JSON contract documented in `log_schema.md`), `slack` (Slack incoming-webhook `attachments[]` with color sidebar), or `discord` (Discord `embeds[]` with decimal RGB). |
| `CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS` | *(none)* | Float; per-miner hashrate floor in GH/s. Rule disabled when unset. Fires `alert.fired` / `rule: "hashrate_below"` when the per-miner `SUMMARY.GHS 5s` drops below this. |
| `CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C` | *(none)* | Float; per-miner temperature ceiling in °C (max-over-chips, matching the operator-visible view). Rule disabled when unset. |
| `CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS` | *(none)* | Integer; fires when `now - last_ok_sample_ts` exceeds this. Rule disabled when unset. Falls back to the miner's earliest poll sample when no successful poll has ever been observed. |
| `CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS` | `300` | Integer > 0. While a rule stays violating, re-emits `alert.fired` every `cooldown_seconds` so consumers that drop a notification get re-paged. |
| `CGMINER_MONITOR_ALERTS_WEBHOOK_TIMEOUT_SECONDS` | `2` | Integer > 0. Both open and read timeout for the `Net::HTTP::Post` call. Caps how much a slow webhook can delay the next poll. |
| `CGMINER_MONITOR_RESTART_SCHEDULE_URL` | *(none)* | URL to `cgminer_manager`'s `GET /api/v1/restart_schedules.json`. When set, AlertEvaluator suppresses the `offline` rule for any miner currently in its scheduled restart window so a nightly restart doesn't page on its way down. Validated at boot (scheme must be http/https, non-empty host). Unset → suppression disabled, offline rule fires normally. |
| `CGMINER_MONITOR_RESTART_WINDOW_GRACE_SECONDS` | `300` | Integer > 0. How long after the scheduled minute to keep suppressing offline alerts (one-sided window — only after the scheduled time, not before). 5 min is roughly the longest a healthy cgminer takes to come back from a restart. |

`Config#validate!` fails hard on: non-positive `interval`, unknown `log_format`, nonexistent `miners_file`, unknown `log_level`. Integer parse errors surface the offending env var name verbatim. When `ALERTS_ENABLED=true`, a separate `validate_alerts!` block additionally requires: webhook URL present + host-nonempty + scheme in `{http, https}`; format in `{generic, slack, discord}`; **at least one** of `HASHRATE_MIN_GHS` / `TEMPERATURE_MAX_C` / `OFFLINE_AFTER_SECONDS` set (empty-but-defined floats/ints fail loudly rather than silently disabling a rule). When `RESTART_SCHEDULE_URL` is set, `validate_restart_window!` requires: scheme http/https, non-empty host, positive grace.

## 3. `miners.yml`

YAML array of miner descriptors. Loaded at boot by `Server#validate_startup!` and by `Poller#build_miner_pool`.

```yaml
- host: 192.168.1.10
  port: 4028
  timeout: 5
- host: 192.168.1.11
  port: 4028
- host: miner3.local
```

| Key | Required | Type | Default |
|---|---|---|---|
| `host` | yes | string (IP or hostname) | — |
| `port` | no | integer | `4028` (cgminer default) |
| `timeout` | no | integer (seconds) | whatever `cgminer_api_client` defaults to (currently 5s) |

Parsed with `YAML.safe_load_file`. An empty array or missing file fails `validate_startup!` as a `ConfigError`.

## 4. HTTP API

Base URL: `http://<host>:<port>/` where host/port come from `CGMINER_MONITOR_HTTP_HOST` / `CGMINER_MONITOR_HTTP_PORT` (defaults `127.0.0.1:9292`).

### Health

```
GET /v2/healthz
```

Returns a snapshot of liveness/readiness.

HTTP status:
- `200` if `status ∈ {healthy, starting}`
- `503` if `status == "degraded"`

Response body:
```json
{
  "status": "healthy",
  "mongo": true,
  "last_poll_at": "2026-04-19T13:45:12Z",
  "last_poll_age_s": 17,
  "miners_configured": 3,
  "miners_available": 3,
  "uptime_s": 1234
}
```

State transitions:
- `starting` — Mongo is up, no poll has happened yet, and uptime < `CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE`.
- `healthy` — Mongo is up and the most recent poll is newer than `interval * healthz_stale_multiplier` seconds.
- `degraded` — anything else (Mongo unreachable, polls stale, or the startup grace window has elapsed without a poll).

### Prometheus metrics

```
GET /v2/metrics
```

`Content-Type: text/plain; version=0.0.4; charset=utf-8`. Exposes:
- `cgminer_hashrate_ghs{miner, window}` — gauge. `window="5s"` and `"avg"`, from `latest_snapshot.summary.SUMMARY[0]`.
- `cgminer_temperature_celsius{miner, device}` — gauge. Per-device from `latest_snapshot.devs.DEVS`.
- `cgminer_available{miner}` — gauge. `1` if the most recent snapshot (any command) was ok; `0` otherwise.
- `cgminer_monitor_polls_total{result="ok"|"failed"}` — counter. Read from the live `Poller` instance.
- `cgminer_monitor_last_poll_age_seconds` — gauge. `-1` if no poll has happened yet.

### Miners list

```
GET /v2/miners
```

```json
{
  "miners": [
    {
      "id": "192.168.1.10:4028",
      "host": "192.168.1.10",
      "port": 4028,
      "available": true,
      "last_poll": "2026-04-19T13:45:12Z"
    }
  ]
}
```

The miners list is derived from `settings.configured_miners` (built once from `miners.yml` by `Server#run`); `available` and `last_poll` come from `latest_snapshot`.

### Per-miner snapshots

```
GET /v2/miners/:miner/summary
GET /v2/miners/:miner/devices
GET /v2/miners/:miner/pools
GET /v2/miners/:miner/stats
```

`:miner` is `host:port` URL-encoded (colon → `%3A`). Unknown miner IDs return `404 {"error": "unknown miner: <id>", "code": "not_found"}`.

Response body:
```json
{
  "miner": "192.168.1.10:4028",
  "command": "summary",
  "fetched_at": "2026-04-19T13:45:12Z",
  "ok": true,
  "response": { "STATUS": [...], "SUMMARY": [...] },
  "error": null
}
```

If no snapshot exists yet, `fetched_at`, `ok`, `response`, and `error` are all `null`.

### Graph data (time-series)

```
GET /v2/graph_data/hashrate
GET /v2/graph_data/temperature
GET /v2/graph_data/availability
```

Query parameters (all optional):
- `miner` — filter to one miner (`host:port`). Omit for pool-wide aggregates.
- `since`, `until` — time range. ISO-8601 (`2026-04-19T12:00:00Z`) or relative (`1h`, `30m`, `7d`, `2w`). Defaults to the last hour.

Response body shape:
```json
{
  "miner": "192.168.1.10:4028",
  "metric": "hashrate",
  "since": "2026-04-19T12:45:12Z",
  "until": "2026-04-19T13:45:12Z",
  "fields": ["ts", "ghs_5s", "ghs_av", "device_hardware_pct", "device_rejected_pct", "pool_rejected_pct", "pool_stale_pct"],
  "data": [[1713534312, 14000000.0, 14010000.0, 0.0, 0.99, 0.99, 0.0], ...]
}
```

`fields` differs per metric:
- **hashrate:** 7 fields as shown above.
- **temperature:** `["ts", "min", "avg", "max"]`.
- **availability (per-miner):** `["ts", "available"]` — `available ∈ {0, 1}`.
- **availability (pool-wide):** `["ts", "available", "configured"]`.

Responses carry `Cache-Control: public, max-age=<interval>` so intermediate caches don't hammer Mongo for the same bucket.

Invalid `since`/`until` values return `400 {"error": "invalid time parameter: <value>", "code": "invalid_request"}`.

### OpenAPI and Swagger UI

```
GET /openapi.yml   → OpenAPI 3.1 spec as text/yaml
GET /docs          → Swagger UI HTML (hits /openapi.yml for the spec)
```

The spec file is packaged with the gem at `lib/cgminer_monitor/openapi.yml` and is CI-guarded for route parity by `spec/openapi_consistency_spec.rb`.

### Error shape

All 4xx/5xx responses use `application/json`:
```json
{ "error": "<human-readable message>", "code": "<machine code>" }
```

Codes: `not_found`, `invalid_request`, `internal`. Unhandled exceptions log `http.unhandled_error` via `Logger.error` and return `500 {"error": "internal", "code": "internal"}` without leaking the exception class or backtrace.

### What the HTTP API does NOT do

- No authentication, no authorization. Anyone who can reach the port can read everything.
- No writes. Nothing mutates state via HTTP; everything in the database was written by the Poller.
- No WebSockets, no streaming, no long-polling. Clients poll the endpoints.
- No support for `HEAD`, `POST`, `PUT`, `DELETE`, or `PATCH`. `OPTIONS` is handled by CORS middleware.

## 5. Upstream: `cgminer_api_client`

Hard runtime dependency (`~> 0.3.0`). Used by `Poller` to talk to cgminer:

- `CgminerApiClient::MinerPool` — parallel fan-out across every configured miner.
- `CgminerApiClient::Miner` — used transiently in `cgminer_monitor doctor` for per-miner `version` pings.
- `CgminerApiClient::MinerResult` — per-miner outcomes inside a `PoolResult`.
- Errors: `CgminerApiClient::ConnectionError`, `CgminerApiClient::ApiError` — caught at the Poller boundary and translated into failed `Snapshot` rows (`ok: false, error: "<ClassName>: <message>"`).

The Poller deliberately does not use `CgminerApiClient::MinerPool.new` (which hard-codes `'config/miners.yml'` relative to CWD). Instead it uses `MinerPool.allocate` + manually sets `.miners=`. See `architecture.md` for why.

## 6. Upstream: MongoDB

Minimum version **5.0** (for time-series collections). CI tests against 6.0 and 7.0; 5.0 isn't available in GitHub Actions service containers but the feature set used has been stable since 5.0.

Connection: single-URI via Mongoid, configured programmatically from `CGMINER_MONITOR_MONGO_URL`. No `mongoid.yml`.

Collections:
- **`samples`** (time-series): `timeField: ts`, `metaField: meta`, `granularity: minutes`, `expire_after: <retention>`. Created by `cgminer_monitor migrate` or `Server#bootstrap_mongoid!`.
- **`latest_snapshot`** (regular): compound unique index on `(miner, command)`, plus an index on `fetched_at`.

Writes use `Sample.collection.insert_many(...)` and `Snapshot.collection.bulk_write(ops, ordered: false)` for throughput. Reads go through `Sample.where(...)` / `Snapshot.where(...)` via Mongoid's `Criteria`, with one raw aggregation pipeline in `SnapshotQuery.miners` for the collapse-per-miner projection.

## Structured log schema

Every log line is a JSON object (default) or a tokenized text line. Guaranteed fields: `ts`, `level`, `event`. Event-specific fields follow.

Notable events (non-exhaustive):
- `server.start`, `server.stopping`, `server.stopped`, `server.crash`
- `puma.crash`
- `poll.complete` with `samples_written`, `snapshots_upserted`, `polls_ok`, `polls_failed`
- `poll.miner_failed` with `miner`, `command`, `error`
- `poll.unexpected_error` with `error`, `message`, `backtrace`
- `mongo.write_failed` with `error`, `message`
- `startup.mongo_unreachable`
- `healthz.mongo_unreachable`
- `migrate.complete`
- `http.unhandled_error` with `error`, `message`, `backtrace`

Log levels: `debug` / `info` / `warn` / `error`. `info` is the default floor.
