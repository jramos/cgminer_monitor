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
| `DEBUG` | unset | Set to `1` for full backtraces on crashes |

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

### Running with Docker

```bash
# Copy and edit miners config
cp config/miners.yml.example config/miners.yml

# Start everything (Mongo + cgminer_monitor)
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

## Security

The HTTP API has **no authentication or authorization**. It is designed for trusted local networks. If exposing to untrusted networks, place it behind a reverse proxy with authentication.

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
