# cgminer_monitor

A standalone monitoring service for [cgminer](https://github.com/ckolivas/cgminer) instances. Periodically polls your miners over the cgminer API, stores device/pool/summary/stats data in MongoDB, and exposes an HTTP API for querying historical and current state.

## Requirements

- **Ruby** 3.2 or higher
- **MongoDB** 5.0 or higher (6.0+ recommended; required for time-series collections)
- **cgminer** instances with API access enabled (`--api-listen --api-allow W:0/0`)

## Dependencies

- [cgminer_api_client](https://github.com/jramos/cgminer_api_client) ~> 0.3.0
- [mongoid](https://github.com/mongodb/mongoid) ~> 9.0
- [sinatra](https://github.com/sinatra/sinatra) >= 4.0
- [puma](https://github.com/puma/puma) >= 6.0
- [rack-cors](https://github.com/cyu/rack-cors) ~> 2.0

## Installation

### RubyGems

```
gem install cgminer_monitor
```

### Bundler

```ruby
gem 'cgminer_monitor', '~> 1.0'
```

### Docker

See [Running with Docker](#running-with-docker) below.

## Configuration

All configuration is via environment variables. No config files are needed except `miners.yml`.

| Variable | Default | Description |
|---|---|---|
| `CGMINER_MONITOR_INTERVAL` | `60` | Poll interval in seconds |
| `CGMINER_MONITOR_RETENTION_SECONDS` | `2592000` (30 days) | Time-series data retention |
| `CGMINER_MONITOR_MONGO_URL` | `mongodb://localhost:27017/cgminer_monitor` | MongoDB connection URI |
| `CGMINER_MONITOR_HTTP_HOST` | `127.0.0.1` | HTTP server bind address |
| `CGMINER_MONITOR_HTTP_PORT` | `9292` | HTTP server port |
| `CGMINER_MONITOR_HTTP_MIN_THREADS` | `1` | Puma minimum threads |
| `CGMINER_MONITOR_HTTP_MAX_THREADS` | `5` | Puma maximum threads |
| `CGMINER_MONITOR_MINERS_FILE` | `config/miners.yml` | Path to miners YAML file |
| `CGMINER_MONITOR_LOG_FORMAT` | `json` | Log format: `json` or `text` |
| `CGMINER_MONITOR_LOG_LEVEL` | `info` | Log level: `debug`, `info`, `warn`, `error` |
| `CGMINER_MONITOR_CORS_ORIGINS` | `*` | CORS allowed origins (comma-separated, or `*`) |
| `CGMINER_MONITOR_SHUTDOWN_TIMEOUT` | `10` | Graceful shutdown timeout in seconds |
| `CGMINER_MONITOR_HEALTHZ_STALE_MULTIPLIER` | `2` | Multiplier on interval for stale-poll detection |
| `CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE` | `60` | Seconds to allow before first poll is expected |
| `CGMINER_MONITOR_PID_FILE` | unset | Path where `run` writes the server PID on boot and unlinks on shutdown. Required for `cgminer_monitor reload`; operators can also `kill -HUP <pid>` directly. |

### Alerts (webhook sink)

Opt-in per-miner threshold alerts. Disabled by default — leave `ALERTS_ENABLED` unset if you alert through Prometheus + Alertmanager against `/v2/metrics` instead.

| Variable | Default | Description |
|---|---|---|
| `CGMINER_MONITOR_ALERTS_ENABLED` | `false` | Master switch. When `false`, all other `ALERTS_*` vars are ignored. |
| `CGMINER_MONITOR_ALERTS_WEBHOOK_URL` | unset | `http(s)://` URL that receives POSTed alerts. Required when enabled. |
| `CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT` | `generic` | One of `generic`, `slack`, `discord`. `generic` is a stable JSON contract; the other two reshape to each platform's incoming-webhook body. |
| `CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS` | unset | Fire `hashrate_below` when a miner's `GHS 5s` drops below this. Leave unset to disable this rule. |
| `CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C` | unset | Fire `temperature_above` when any device temperature exceeds this. Leave unset to disable this rule. |
| `CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS` | unset | Fire `offline` when a miner's last successful poll is older than this. Leave unset to disable this rule. |
| `CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS` | `300` | Minimum time between re-fires of the same `(miner, rule)` while it stays violating. |
| `CGMINER_MONITOR_ALERTS_WEBHOOK_TIMEOUT_SECONDS` | `2` | Per-POST open+read timeout. One attempt, no retry. Failures log `event=alert.webhook_failed` and do not abort the poll loop. |

At least one of the three rule thresholds must be set when `ALERTS_ENABLED=true` — the service refuses to boot otherwise. A Slack example:

```bash
export CGMINER_MONITOR_ALERTS_ENABLED=true
export CGMINER_MONITOR_ALERTS_WEBHOOK_URL='https://hooks.slack.com/services/AAA/BBB/CCC'
export CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT=slack
export CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C=85
export CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS=600
```

See [`docs/log_schema.md`](docs/log_schema.md) for the `alert.*` event catalog and the generic webhook body shape.

### Miners file

Create a `config/miners.yml` with your cgminer instances:

```yaml
- host: 192.168.1.10
  port: 4028
  timeout: 5
- host: 192.168.1.11
  port: 4028
```

## Running

### Local

```bash
# 1. Start MongoDB
docker run -d --name cgminer-mongo -p 27017:27017 mongo:7

# 2. Create collections (idempotent)
cgminer_monitor migrate

# 3. Validate config + connectivity
cgminer_monitor doctor

# 4. Run the service
cgminer_monitor run
```

The service runs in the foreground. Use your process supervisor (systemd, launchd, etc.) for production.

### Hot-reloading miners.yml

`miners.yml` is hot-reloadable — edit the file, then either
`kill -HUP $(cat $CGMINER_MONITOR_PID_FILE)` or
`cgminer_monitor reload`. The service logs `event=reload.ok` on
success or `event=reload.failed` (and keeps the old list) if the new
file fails to parse. Both the poll loop and the HTTP routes pick up
the new list atomically. Only `miners.yml` reloads; changes to
`CGMINER_MONITOR_MONGO_URL`, `CGMINER_MONITOR_INTERVAL`, log level,
etc. still require a restart.

### Running with Docker

Multi-arch images (`linux/amd64` + `linux/arm64`) are published from CI to
GHCR on every `v*` tag push:

```bash
docker pull ghcr.io/jramos/cgminer_monitor:latest
# or pin to a specific release:
docker pull ghcr.io/jramos/cgminer_monitor:1.0
```

Run with the full stack (Mongo + cgminer_monitor):

```bash
# Copy and edit miners config
cp config/miners.yml.example config/miners.yml

# Start everything
docker-compose up

# Or just Mongo for local development
docker-compose up -d mongo
```

### systemd example

```ini
[Unit]
Description=cgminer_monitor
After=network.target mongod.service

[Service]
Type=simple
User=cgminer
WorkingDirectory=/opt/cgminer_monitor
Environment=CGMINER_MONITOR_MONGO_URL=mongodb://localhost:27017/cgminer_monitor
Environment=CGMINER_MONITOR_MINERS_FILE=/opt/cgminer_monitor/config/miners.yml
ExecStartPre=/usr/local/bin/cgminer_monitor migrate
ExecStart=/usr/local/bin/cgminer_monitor run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## CLI Commands

| Command | Description |
|---|---|
| `cgminer_monitor run` | Start the monitoring service (foreground) |
| `cgminer_monitor migrate` | Create MongoDB collections and indexes (idempotent) |
| `cgminer_monitor doctor` | Validate config, test Mongo + miner connectivity |
| `cgminer_monitor version` | Print version and exit |

### Exit codes

Exit codes follow [`sysexits(3)`](https://man.openbsd.org/sysexits.3):

| Code | Meaning |
|---|---|
| `0` | Clean shutdown (signal-driven for `run`; normal completion for `migrate`/`doctor`/`version`). |
| `1` | Unexpected crash (`run`), or a MongoDB error during `migrate`. |
| `64` | `EX_USAGE` — unknown or missing command. |
| `78` | `EX_CONFIG` — configuration validation failed (`run` or `migrate`). |

### Logging

The service writes structured log lines to stdout — one JSON object per line by default. Every line includes `ts`, `level`, `event`, plus event-specific fields. Library code never writes directly to stderr; the CLI itself only uses stderr for top-level error messages and usage hints.

Toggles:
- `CGMINER_MONITOR_LOG_FORMAT=text` switches to a tokenized `ts LEVEL event k=v` format for human reading. `json` (default) is what most log aggregators want.
- `CGMINER_MONITOR_LOG_LEVEL` filters at `debug` / `info` / `warn` / `error`. Default is `info`; raise to `warn`/`error` to reduce volume in production, or drop to `debug` when troubleshooting.

Notable events you'll see: `server.start`, `server.stopping`, `server.stopped`, `poll.complete`, `poll.miner_failed`, `poll.unexpected_error`, `mongo.write_failed`, `startup.mongo_unreachable`, `healthz.mongo_unreachable`, `http.unhandled_error`. Use these as the primary signal for monitoring pipelines.

## API Reference

The HTTP API is available at `http://localhost:9292` by default. Interactive documentation is at [`/docs`](http://localhost:9292/docs) (Swagger UI).

### Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/v2/healthz` | Liveness/readiness check (200 healthy/starting, 503 degraded) |
| GET | `/v2/metrics` | Prometheus text exposition endpoint |
| GET | `/v2/miners` | List configured miners with availability |
| GET | `/v2/miners/:miner/summary` | Latest summary snapshot for a miner |
| GET | `/v2/miners/:miner/devices` | Latest devs snapshot for a miner |
| GET | `/v2/miners/:miner/pools` | Latest pools snapshot for a miner |
| GET | `/v2/miners/:miner/stats` | Latest stats snapshot for a miner |
| GET | `/v2/graph_data/hashrate` | Hashrate time series |
| GET | `/v2/graph_data/temperature` | Temperature time series (min/avg/max) |
| GET | `/v2/graph_data/availability` | Availability time series |
| GET | `/openapi.yml` | OpenAPI 3.1 specification |
| GET | `/docs` | Swagger UI |

### Time range parameters

Graph data endpoints accept `since` and `until` query parameters in two formats:

- **ISO-8601:** `2026-04-15T12:00:00Z`
- **Relative:** `1h`, `30m`, `7d`, `2w`

Default range is the last hour when both are omitted.

### Miner ID format

Miners are identified by `host:port` (e.g., `192.168.1.10:4028`). URL-encode the colon when using path parameters: `192.168.1.10%3A4028`.

## Architecture

cgminer_monitor is a standalone process (not a Rails engine). It runs two threads:

1. **Poller** — periodically queries all configured miners via `cgminer_api_client`, writes numeric samples to a MongoDB time-series collection (`samples`) and full responses to a regular collection (`latest_snapshot`).
2. **HTTP server** (Puma + Sinatra) — serves the API from the MongoDB collections.

### Storage

- **`samples`** — MongoDB time-series collection. Flat `{ts, meta, v}` rows. Each numeric field from each cgminer command becomes a sample. Used for graph data queries.
- **`latest_snapshot`** — Regular collection. One document per `(miner, command)`, upserted each poll. Holds the full verbatim cgminer response. Used for current-state queries.

## Migration from 0.x

See [MIGRATION.md](MIGRATION.md) for a detailed guide on migrating from cgminer_monitor 0.x (the Rails engine version).

## Security posture

Default bind is `127.0.0.1:9292`. The service is designed for trusted local networks; to expose it beyond localhost, put it behind a reverse proxy that terminates TLS. The HTTP API has no authentication and intentionally doesn't — adding auth piecemeal to a read-only telemetry surface is worse than having the trust boundary clearly in scope. If you need auth, layer it at the reverse proxy.

The `/v2/*` endpoints expose operationally sensitive data that should not cross an untrusted network in plaintext:

- `/v2/miners` — the configured miner list, including host:port of every rig.
- `/v2/miners/:id/{summary,stats,devices,pools}` — per-rig hashrate, temperature, device inventory, and pool URLs + usernames. Pool passwords are typically redacted by cgminer (`***`), but this is firmware-dependent and not guaranteed — some forks return the literal password.
- `/v2/graph_data/{hashrate,temperature,availability}` — time-series per rig.
- `/v2/metrics` — Prometheus exposition with per-miner, per-device labeled gauges (`cgminer_hashrate_ghs`, `cgminer_temperature_celsius`, `cgminer_available`) plus fleet-wide `cgminer_monitor_polls_total` and `cgminer_monitor_last_poll_age_seconds`. This is the whole fleet inventory in a single GET and is the strongest argument for TLS.
- `/v2/healthz` — fleet-size disclosure: `miners_configured`, `miners_available`, `last_poll_age_s`, `uptime_s`.
- `/openapi.yml` and `/docs` — the schema and a live Swagger UI.

### Reverse proxy with TLS

Terminate TLS at nginx (or your proxy of choice) and point it at the loopback bind:

    server {
        listen 443 ssl http2;
        server_name monitor.example.com;

        ssl_certificate     /etc/letsencrypt/live/monitor.example.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/monitor.example.com/privkey.pem;

        location / {
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_pass http://127.0.0.1:9292;  # adjust if CGMINER_MONITOR_HTTP_PORT is not 9292
        }
    }

Layer `auth_basic` at the `location` block if you want HTTP Basic Auth on top; monitor itself doesn't gate requests, so the proxy is the right place for it. If Prometheus scrapes `/v2/metrics` across a network boundary, scrape it through the same proxy rather than exposing `127.0.0.1:9292` directly.

Monitor also writes to MongoDB over `CGMINER_MONITOR_MONGO_URL`; if Mongo lives on a separate host, that link is operator-configured and plaintext by default. Use Mongo's own TLS + auth support (or a private network) to keep the write path as well-protected as the read surface.

## Further Reading

- [`CHANGELOG.md`](CHANGELOG.md) — release history, starting with the 1.0.0 ground-up rewrite.
- [`MIGRATION.md`](MIGRATION.md) — step-by-step upgrade guide from the 0.x Rails-engine era.
- [`AGENTS.md`](AGENTS.md) — context for AI coding assistants; also a useful conventions-and-extension guide for human contributors.
- [`docs/`](docs/) — topic-split deep dives on architecture, components, interfaces, data models, workflows, and dependencies. Start with [`docs/index.md`](docs/index.md).

## Contributing

1. Fork it (https://github.com/jramos/cgminer_monitor/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Donating

If you find this gem useful, please consider donating.

BTC: `bc1q00genlpcpcglgd4rezqcurf4t4taz0acmm9vea`

## License

Code released under [the MIT license](LICENSE.txt).
