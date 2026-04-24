# Data Models

cgminer_monitor stores two kinds of thing in MongoDB: **samples** (time-series of numeric metrics) and **latest_snapshot** (most recent cgminer response per miner per command). Nothing else is persisted. In-memory, there's also the immutable `Config` value object and the `Error` hierarchy.

## Persistent models

### `CgminerMonitor::Sample` → `samples` time-series collection

MongoDB time-series collection (Mongo 5.0+ feature). Very thin Mongoid model.

```mermaid
classDiagram
    class Sample {
        <<time-series>>
        +ts: Time
        +meta: Hash
        +v: Float
    }
    class meta_shape {
        <<Hash contents>>
        +miner: "host:port"
        +command: "summary"|"devs"|"pools"|"stats"|"poll"
        +sub: Integer
        +metric: String
    }
    Sample --> meta_shape : has
```

**Collection-level shape** (set by `Server#bootstrap_mongoid!` or `cgminer_monitor migrate`):
- `timeField: "ts"`
- `metaField: "meta"`
- `granularity: "minutes"` — optimizes internal bucketing for our ~1/minute write rate.
- `expire_after: <retention_seconds>` — applied as a TTL via Mongo's time-series-native TTL support. Defaults to 30 days; set via `CGMINER_MONITOR_RETENTION_SECONDS`.

**No indexes beyond the implicit time-series indexes.** Mongo manages them based on `timeField` + `metaField`.

**Why `store_in` is called programmatically.** Two reasons: `expire_after` depends on runtime config that doesn't exist at class-load time, and Mongoid's lazy `create_collection` would produce a regular collection rather than a time-series one if we didn't call `create_collection` explicitly after configuring `store_in`. See the comment in `lib/cgminer_monitor/sample.rb`.

**Sample row examples:**

```ruby
# A hashrate sample from a summary response
{ ts: 2026-04-19 13:45:12 UTC,
  meta: { miner: "192.168.1.10:4028", command: "summary", sub: 0, metric: "ghs_5s" },
  v: 14000000.0 }

# A temperature sample from a devs response
{ ts: 2026-04-19 13:45:12 UTC,
  meta: { miner: "192.168.1.10:4028", command: "devs", sub: 2, metric: "temperature" },
  v: 65.0 }

# A synthetic per-poll availability sample (metric: ok)
{ ts: 2026-04-19 13:45:12 UTC,
  meta: { miner: "192.168.1.10:4028", command: "poll", sub: 0, metric: "ok" },
  v: 1.0 }

# A synthetic per-poll duration sample
{ ts: 2026-04-19 13:45:12 UTC,
  meta: { miner: "192.168.1.10:4028", command: "poll", sub: 0, metric: "duration_ms" },
  v: 142.3 }
```

**How keys get there (`Poller#normalize_metric`):**
- Lowercase.
- Spaces → underscores.
- `%` → `_pct`.

So `"MHS av"` → `mhs_av`, `"Pool Rejected%"` → `pool_rejected_pct`, `"Last Share Time"` → `last_share_time`.

**Only numeric fields become samples.** Strings (device names, pool URLs, worker names) are silently skipped in `extract_samples` — but the full response (strings included) is still preserved in `latest_snapshot`.

### `CgminerMonitor::Snapshot` → `latest_snapshot` regular collection

Regular Mongoid collection. One doc per `(miner, command)` pair, upserted every poll.

```mermaid
classDiagram
    class Snapshot {
        <<document>>
        +miner: String
        +command: String
        +fetched_at: Time
        +ok: Boolean
        +response: Hash?
        +error: String?
    }
```

**Fields:**
- `miner` — `"host:port"` string.
- `command` — one of `"summary"`, `"devs"`, `"pools"`, `"stats"`.
- `fetched_at` — when the poll started.
- `ok` — `true` if cgminer answered and the response parsed; `false` on connection failures or `STATUS=E/F`.
- `response` — the full cgminer response hash (envelope + command data). Null when `ok` is false.
- `error` — `"<ErrorClass>: <message>"` when `ok` is false. Null when `ok` is true.

**Indexes:**
- `{miner: 1, command: 1}` **unique** — enforces one doc per key pair. Drives the per-miner snapshot route.
- `{fetched_at: 1}` — supports healthz's "oldest poll" check and the SnapshotQuery aggregations.

**Why a regular collection rather than time-series:** `latest_snapshot` is write-heavy by upsert (one write per miner per command per poll cycle), and reads mostly look up single rows by compound key. Time-series wouldn't buy anything here.

### `CgminerMonitor::AlertState` → `alert_states` regular collection

Regular Mongoid collection. One doc per `(miner, rule)` pair, upserted by the `AlertEvaluator` on each poll tick — provided alerts are enabled. Collection is empty when `alerts_enabled=false`. Exists only to persist per-rule state across restart so a hashrate-below-threshold rig doesn't re-page on every monitor cold-start.

```mermaid
classDiagram
    class AlertState {
        <<document>>
        +_id: String
        +miner: String
        +rule: String
        +state: String
        +threshold: Float
        +last_observed: Float
        +last_fired_at: Time?
        +last_transition_at: Time
    }
```

**Fields:**
- `_id` — composite `"#{miner}|#{rule}"`. Overrides Mongoid's default `BSON::ObjectId` via a default lambda; enforces `(miner, rule)` uniqueness through the implicit `_id` index.
- `miner` — `"host:port"` string.
- `rule` — one of `"hashrate_below"`, `"temperature_above"`, `"offline"`.
- `state` — `"ok"` or `"violating"`.
- `threshold` — snapshot of the configured threshold at emit time (float; seconds for `offline`).
- `last_observed` — most recent metric reading; diagnostic only.
- `last_fired_at` — set on fire, preserved on cooldown-held re-violation. Drives cooldown checks: `(now - last_fired_at) >= cooldown_seconds` means a re-fire is due.
- `last_transition_at` — most recent ok↔violating transition.

**Indexes:** only the implicit `_id` index. No secondary index needed; the composite `_id` shape *is* the compound key.

### Writes go in bulk, reads use simple criteria

The Poller issues one `insert_many` per poll cycle for samples (potentially hundreds of rows) and one `bulk_write` with `ordered: false` for snapshots. `ordered: false` means one miner's snapshot upsert failing doesn't block the others.

Reads use straightforward `Sample.where(...)` and `Snapshot.where(...)` criteria chains, with one raw aggregation pipeline in `SnapshotQuery.miners` for the "collapse snapshots per miner" projection.

## In-memory models

### `CgminerMonitor::Config` (`Data.define`)

Immutable value object. Built from `ENV` via `Config.from_env` at boot, validated once, cached via `Config.current`.

```mermaid
classDiagram
    class Config {
        <<Data.define>>
        +interval: Integer
        +retention_seconds: Integer
        +mongo_url: String
        +http_host: String
        +http_port: Integer
        +http_min_threads: Integer
        +http_max_threads: Integer
        +miners_file: String
        +log_format: String
        +log_level: String
        +cors_origins: String
        +shutdown_timeout: Integer
        +healthz_stale_multiplier: Integer
        +healthz_startup_grace_seconds: Integer
        +validate!() Config
        +public_attrs() Hash
        +redact_mongo_url(url)
    }
```

**Invariants (enforced by `validate!`):**
- `interval > 0`
- `log_format ∈ {"json", "text"}`
- `log_level ∈ {"debug", "info", "warn", "error"}`
- `File.exist?(miners_file)`

**`public_attrs`** returns `to_h` with `mongo_url` redacted (`mongodb://user:pass@host` → `mongodb://[REDACTED]@host`). Used by `cgminer_monitor doctor`; also supplies the redacted `mongo_url` value emitted in the `server.start` structured-log entry.

**Immutable by design.** Config cannot be mutated at runtime. A config change requires a restart. Justified because the process model is supervisor-driven and a restart is cheap.

### Error class hierarchy

```mermaid
classDiagram
    StandardError <|-- Error
    Error <|-- ConfigError

    class Error { <<CgminerMonitor::Error>> }
    class ConfigError { raised by Config#validate! and env parsing }
```

- `Error` — base class for gem-specific errors. Rescuable with `rescue CgminerMonitor::Error`.
- `ConfigError` — raised on bad env values and missing `miners.yml`; CLI translates to exit 78.

External errors (`Mongo::Error` from the driver, `CgminerApiClient::ConnectionError` / `ApiError` from the upstream client) are caught at their boundaries and either logged (`mongo.write_failed`, `poll.unexpected_error`) or attached to failed `Snapshot` docs (`ok: false, error: "<class>: <msg>"`) rather than rewrapped as gem-specific errors.

### PoolResult and MinerResult (from `cgminer_api_client`)

Not defined by this gem, but part of the data model that flows through it. `Poller#poll_miner` iterates `MinerResult` instances inside a `PoolResult`:

```ruby
pool_result  = @miner_pool.query('summary')   # → PoolResult
miner_result = pool_result[miner_id]          # → MinerResult
if miner_result&.ok?
  response = miner_result.value.is_a?(Array) ? miner_result.value.first : miner_result.value
  # extract samples, build snapshot upsert
else
  # attach error string to snapshot upsert
end
```

See `cgminer_api_client/docs/data_models.md` in the sibling repo for that object shape.

## Raw vs. stored response shape

cgminer's wire format looks like this (after `cgminer_api_client` parses and normalizes it):

```ruby
{
  status: [{ status: "S", when: 1700000000, code: 11, msg: "Summary", description: "cgminer 4.11.1" }],
  summary: [{ elapsed: 12345, mhs_av: 56789.12, ghs_5s: 14000000.0, ... }],
  id: 1
}
```

`cgminer_api_client`'s convenience `summary`/`coin`/`config`/`version`/`check` methods unwrap the single-element array for you, but the Poller calls `pool.query('summary')` directly, which returns the envelope form. `Poller#process_success` handles both shapes:

```ruby
response = miner_result.value.is_a?(Array) ? miner_result.value.first : miner_result.value
```

The Poller also stores cgminer's **original** key casing in the `response` field of `latest_snapshot` (because it was parsed by api_client into sanitized, symbolized keys, then the response shape is a Hash of the whole envelope — effectively what comes off the wire). The **sanitized-then-lowercased-snake_case** keys only appear in the `samples` meta (via `normalize_metric`).

This has a subtle implication for the Prometheus endpoint (`HttpApp#build_prometheus_metrics`): it defensively checks both casings when reading from `latest_snapshot`:
```ruby
ghs_5s = summary['GHS 5s'] || summary['ghs_5s']
```
So adding a new metric that has different casing in different cgminer versions is handled by trying both forms.

## Why two collections instead of one

Because the read patterns are totally different:
- **"What's happening right now with miner X"** → one row lookup by `(miner, command)`. Regular collection with a unique compound index. Fast, cheap, always current.
- **"What was my hashrate over the last 2 hours"** → many rows by time range, grouped by ts. Time-series collection with automatic bucketing and Mongo-managed indexes. Fast, bounded retention, scales out.

Trying to serve both from one collection would either slow down graph queries (they'd scan enormous non-bucketed rows) or bloat snapshots (they'd carry all historical data). Separation was the single biggest structural call in the 1.0 rewrite.
