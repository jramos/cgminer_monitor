# Structured log schema

Canonical contract for the structured logs emitted by the three sibling gems:

- `cgminer_monitor` — owns the poll loop and the time-series HTTP API.
- `cgminer_manager` — owns the admin/rate-limit/UI surface and client calls to monitor.
- `cgminer_api_client` — **silent by design.** Raises on failure, returns result objects on success. No `Logger` module, no log call sites. Callers own the emission. See `cgminer_api_client/docs/logging.md`.

Log consumers (Loki, Datadog, Vector, grep) can treat this document as the source of truth for key names, types, and event namespaces. All three repos link here rather than duplicate the contract.

## Scope + non-goals

- **Covered:** every `Logger.{debug,info,warn,error}(...)` call site in `cgminer_monitor/lib/` and `cgminer_manager/lib/`.
- **Not covered:** Puma's own startup/shutdown logs, Rack-level access logs (those flow through Puma's stdout independently), MongoDB client logs, Mongoid query logs. These use their own formats and are out of contract.
- **Not covered:** ad-hoc `puts` / `STDERR.puts` in CLI binstubs for human-readable output (`doctor`, `reload`, `migrate`). CLI output is for humans; structured logs are for machines.

## Transport

- Single-line JSON per event on stdout, by default (`Logger.format = 'json'`).
- Humans set `Logger.format = 'text'` to get `ts LEVEL event k=v k=v` for local debugging; the text form is not a parseable contract.
- `Logger.level` filters by the ordered set `debug < info < warn < error`. Default: `info`.

## Reserved always-present keys

Every JSON object emitted by the house `Logger` module begins with these three keys before any caller-supplied fields:

| Key     | Type   | Format                                        | Notes                                                  |
|---------|--------|-----------------------------------------------|--------------------------------------------------------|
| `ts`    | string | ISO-8601 UTC with millisecond precision       | `2026-04-23T18:03:02.697Z`                             |
| `level` | string | one of `debug`, `info`, `warn`, `error`       | lowercase; no `trace`/`fatal`                          |
| `event` | string | dotted lowercase `<namespace>.<action>`       | always present; grep-anchor                            |

The `event` value is the single most important key — every downstream consumer should route/filter on it first.

## Standard keys

Keys that appear across multiple events are named consistently. When you add a new event, prefer reusing a standard key over minting a new one.

| Key               | Type             | Example                                     | Meaning / notes |
|-------------------|------------------|---------------------------------------------|-----------------|
| `pid`             | integer          | `42315`                                     | `Process.pid` of the emitter |
| `bind`            | string           | `"127.0.0.1"`                               | HTTP bind host |
| `port`            | integer          | `9292`                                      | HTTP listen port |
| `path`            | string           | `"/manager/admin/version"`                  | Rack `request.path`; also used for pid-file paths on `server.pid_file_written` |
| `method`          | string           | `"POST"`                                    | HTTP verb, uppercase |
| `status`          | integer          | `200`                                       | HTTP response code |
| `url`             | string           | `"/v2/miners"`                              | outbound URL (e.g. manager → monitor) |
| `duration_ms`     | integer          | `1234`                                      | milliseconds, rounded. **Standardized name** — do not use `elapsed_ms`, `render_ms`, `took_ms`, or `latency_ms` |
| `error`           | string           | `"Mongo::Error::OperationFailure"`          | exception class name via `e.class.to_s`. Never an exception object |
| `message`         | string           | `"Connection refused"`                      | `e.message` |
| `backtrace`       | array\<string\>  | `["file.rb:42 in …", …]`                    | first 10 frames by convention (`e.backtrace&.first(10)`) |
| `code`            | string           | `"access_denied"`                           | symbolic error tag for log-side dispatch. Six values: `access_denied`, `invalid_command`, `unknown`, `timeout`, `connection_error`, `unexpected`. Maps from any `cgminer_api_client::ApiError` (including subclasses like `AccessDeniedError`) via `#code` (v0.4.0+) when the wire returned a structured error; consumers synthesize `timeout` for `CgminerApiClient::TimeoutError` and `connection_error` for `CgminerApiClient::ConnectionError`. **`unexpected` should not occur in practice** — its presence indicates a rescue widened upstream of the consumer (or a non-`CgminerApiClient` exception slipped through), and is worth surfacing as an alert. |
| `remote_ip`       | string           | `"192.0.2.10"`                              | client IP (post-trust-walk for proxied requests) |
| `user_agent`      | string           | `"curl/8.9.1"`                              | raw `HTTP_USER_AGENT` |
| `user`            | string or `nil`  | `"admin"`                                   | admin-surface Basic-Auth username; `nil` when unauthenticated |
| `session_id_hash` | string           | `"a3f1e2d4b6c8"`                            | first 12 hex chars of `SHA256(session_id)`; never the raw session id |
| `confirmation_token` | string        | UUID v4                                     | single-use 2-minute TTL token issued by the destructive-command confirmation flow (`cgminer_manager` v1.7.0+); appears on `admin.action_*` events and threads step 1 → step 2 of a two-phase POST |
| `reason`          | string (Symbol)  | `"expired"` / `"session_mismatch"` / `"evicted"` / `"not_found"` / `"missing_credentials"` | enum-like discriminator on rejection-style events. Values vary per event (e.g. `admin.auth_failed.reason` is a different enum than `admin.action_rejected.reason`); each emit-site documents its set. |
| `request_id`      | string           | UUID v4                                     | threads entry/exit events for a single admin POST |
| `command`         | string           | `"version"`, `"addpool"`                    | cgminer verb or admin command name |
| `scope`           | string           | `"all"`, `"rig-01"`, `"pool-0"`             | admin-command target selector |
| `args`            | hash             | `{ pool_id: "0" }`                          | optional extra context on admin events; shape is per-command |
| `reason`          | string           | `"missing_credentials"`                     | short enum-like string on auth-failure events |
| `retry_after`     | integer          | `42`                                        | seconds; paired with 429 responses |
| `miner`           | string           | `"10.0.0.5:4028"`                           | scalar rig identifier — `"host:port"` |
| `miners`          | integer          | `3`                                         | count of miners (or an array where the emit site documents it). Never a single rig |
| `rule`            | string           | `"hashrate_below"`                          | alert rule name. Built-in rules: `hashrate_below`, `temperature_above`, `offline`. For composite rules (v1.4.0+), the value is the operator-defined composite name (e.g. `thermal_stress`). |
| `threshold`       | number or string | `1000.0`                                    | snapshot of the configured threshold at emit time (alert events only). String for composite rules (e.g. `"ghs_5s<500.0 & temp_max>80.0"`); number for built-in rules. |
| `observed`        | number or string | `732.5`                                     | the observed value that triggered a fire/resolve (alert events only). String for composite rules (e.g. `"ghs_5s=450.0 temp_max=82.0"`); number for built-in rules. |
| `unit`            | string or null   | `"GH/s"`                                    | unit for `threshold`/`observed` — `"GH/s"`, `"C"`, or `"seconds"` for built-ins. `null` for composite rules (the threshold/observed strings already carry the per-metric context). |
| `details`         | hash             | `{"expression":"…","clauses":{…}}`          | composite-rule structured payload (alert events only). Includes the canonical `expression` string and a per-`clauses` map of `{observed, threshold, op}` entries. Absent for built-in rules. |
| `built_in_rules`  | array of strings | `["temperature_above"]`                     | enabled built-in rule names (`alert.config_loaded` only) |
| `composite_rules` | array of strings | `["thermal_stress"]`                        | enabled composite rule names (`alert.config_loaded` only) |
| `log_format`      | string           | `"json"` or `"text"`                        | effective formatter — `server.start` only |
| `log_level`       | string           | `"info"`                                    | effective level threshold — `server.start` only |
| `mongo_url`       | string           | `"mongodb://[REDACTED]@db:27017/monitor"`   | always credential-redacted; `server.start` only |
| `ok_count`        | integer          | `2`                                         | admin-command scope hits that succeeded |
| `failed_count`    | integer          | `1`                                         | admin-command scope hits that failed |
| `samples_written` | integer          | `48`                                        | Mongo write count on a poll tick |
| `snapshots_upserted` | integer       | `12`                                        | Mongo upsert count on a poll tick |
| `polls_ok`        | integer          | `12`                                        | miners polled successfully on a tick |
| `polls_failed`    | integer          | `0`                                         | miners that errored on a tick |
| `poller_ok`       | boolean          | `true`                                      | reload-partial diagnostic |
| `http_app_ok`     | boolean          | `false`                                     | reload-partial diagnostic |

**Convention:** scalar `miner:` for a rig id (string `"host:port"`); plural `miners:` for a count (integer). Reserved — don't reintroduce `miner_id:` or use `miner:` for an array.

## Correlation

`request_id` (UUID v4) is generated at the edge of every HTTP request in the manager and the monitor and propagated end-to-end so a single value recovers the full causal chain across all three repos.

**Origin rules:**

- Manager generates `request_id` for every inbound HTTP request via Rack middleware sitting above `RateLimiter` and `AdminAuth`. Stashed on `env['cgminer_manager.request_id']`.
- Monitor reads `HTTP_X_CGMINER_REQUEST_ID` from inbound requests; if absent (e.g., direct `curl`, Prometheus scraper), generates its own UUID. Stashed on `env['cgminer_monitor.request_id']`.
- Manager's `MonitorClient` injects `X-Cgminer-Request-Id` on every outbound HTTP call to monitor.
- Manager's `FleetBuilders` builds per-request `Miner` instances with a closure-captured `on_wire` callback; api_client's wire telemetry surfaces as `cgminer.wire` log events tagged with the request_id (debug level — opt in via `LOG_LEVEL=debug` to avoid the ~100-200 events per fan-out at info volume).

**Reserved-name discipline.** The header is `X-Cgminer-Request-Id` (canonical casing, but HTTP is case-insensitive). Don't introduce alternative names (`X-Trace-Id`, `X-Correlation-Id`).

**Background work has no `request_id`.** Monitor's `poll.*`, `alert.*`, `mongo.*`, `migrate.*` events fire from the timer thread, not from inbound HTTP requests, so they don't carry the key. Forcing a value would dilute the dispatch signal.

**Recipe — recover a full causal chain across both repos:**

```sh
jq -c 'select(.request_id == "a1b2c3d4-0000-0000-0000-000000000000")' \
  manager.log monitor.log
```

## Namespace reservations

Namespaces partition the event space; each prefix is owned by exactly one repo except where noted.

**cgminer_monitor only:**

- `alert.*` — per-miner threshold alerts evaluated at end-of-poll (`alert.fired`, `alert.resolved`, `alert.webhook_failed`, `alert.evaluator_error`, `alert.state_write_failed`, `alert.evaluation_complete`). Opt-in via `CGMINER_MONITOR_ALERTS_ENABLED=true`.
- `poll.*` — the monitoring poll loop (`poll.complete`, `poll.miner_failed`, `poll.unexpected_error`).
- `mongo.*` — Mongo write failures from the poll loop (`mongo.write_failed`).
- `migrate.*` — one-shot index/migration operations (`migrate.complete`).
- `startup.*` — pre-Puma startup validation (`startup.mongo_unreachable`).
- `healthz.*` — readiness-probe results (`healthz.mongo_unreachable`).

**cgminer_manager only:**

- `admin.*` — admin surface (`admin.command`, `admin.result`, `admin.auth_failed`, `admin.auth_misconfigured`).
- `rate_limit.*` — rate-limiter (`rate_limit.exceeded`).
- `monitor.*` — **manager's client calls to the monitor service** (`monitor.call`, `monitor.call.failed`). This is intentional: the prefix names the *dependency*, not the emitter.
- `cgminer.*` — **manager's wire telemetry from api_client commands** (`cgminer.wire`). Same convention as `monitor.*`: the prefix names the *dependency* (cgminer firmware), not the emitter. Debug-level by default.
- `http.*` — Rack request-level events (`http.request`, `http.500`, `http.unhandled_error`). Manager emits `http.request` + `http.500`; monitor emits `http.request` + `http.unhandled_error` (added in v1.3.0). Technically shared.

**Shared (emitted by both):**

- `server.*` — process lifecycle (`server.start`, `server.stopping`, `server.stopped`, `server.crash`, `server.pid_file_written`).
- `reload.*` — SIGHUP hot-reload (`reload.signal_received`, `reload.ok`, `reload.failed`). `reload.partial` is monitor-only within this namespace — emitted from `lib/cgminer_monitor/server.rb` when Poller + HttpApp reload outcomes diverge; no manager equivalent because manager has no Poller.
- `puma.*` — Puma-thread crashes (`puma.crash`).
- `http.unhandled_error` — emitted by both repos for uncaught exceptions below the Sinatra error handler.

## Event catalog

Organized alphabetically within namespace. "Required" columns list keys beyond the reserved triple (`ts`, `level`, `event`).

### `admin.*` (cgminer_manager)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `admin.auth_failed` | warn | `AdminAuth` | `request_id`, `reason`, `path`, `remote_ip`, `user_agent` | |
| `admin.auth_misconfigured` | warn | `AdminAuth` | `request_id`, `path`, `remote_ip`, `user_agent` | |
| `admin.command` | info | `HttpApp` via `AdminLogging.command_log_entry` | `request_id`, `user`, `remote_ip`, `user_agent`, `session_id_hash`, `command`, `scope` | `args` and other per-command extras |
| `admin.result` | info | `HttpApp` via `AdminLogging.result_log_entry` | `request_id`, `command`, `scope`, `ok_count`, `failed_count`, `duration_ms` | `failed_codes` (count-by-`code`-value map of failed entries, e.g. `{"access_denied": 3, "unknown": 2}`; map keys obey the `code` standard-key vocabulary; empty `{}` when `failed_count == 0`) |
| `admin.action_started` | info | `HttpApp` via `ConfirmationHelpers#issue_confirmation_token` (`cgminer_manager` v1.7.0+) | `request_id`, `confirmation_token`, `expires_at`, `command`, `scope`, `session_id_hash`, `remote_ip`, `user_agent` | `user`, `args` (subject to redaction for `manage_pools/add` actions where `args` becomes `"[REDACTED: pool credentials]"`) |
| `admin.action_confirmed` | info | `HttpApp` (post `POST /manager/admin/confirm/:token`) | `request_id`, `confirmation_token`, `command`, `scope`, `session_id_hash`, `remote_ip`, `user_agent`, `started_age_ms` | `user`, `args` (same redaction rule) |
| `admin.action_auto_confirmed` | info | `HttpApp` via `ConfirmationHelpers` (when `?auto_confirm=1` skips the dance) | `request_id`, `command`, `scope`, `session_id_hash`, `remote_ip`, `user_agent` | `user` |
| `admin.action_cancelled` | info | `HttpApp` (post `DELETE /manager/admin/confirm/:token`) | `request_id`, `confirmation_token`, `command`, `scope`, `session_id_hash` | `user` |
| `admin.action_rejected` | warn | `HttpApp` via `ConfirmationHelpers#reject_confirmation!` and `#log_eviction` | `request_id`, `confirmation_token`, `reason`, `session_id_hash` | `command`, `scope`, `user` (nil for `reason: :not_found` since the token's command/scope aren't recoverable). `reason` is one of `:expired`, `:session_mismatch`, `:evicted`, `:not_found` — single event with discriminator instead of one event per failure mode. |

### `cgminer.*` (cgminer_manager)

Manager's per-command wire telemetry, emitted at debug level (opt-in via `LOG_LEVEL=debug`). Closure-captured `request_id` flows through every event so a single value recovers the full causal chain across an admin POST → fan-out → cgminer round-trip.

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `cgminer.wire` | debug | `FleetBuilders.build_wire_logger` (closure passed as `on_wire:` to per-request `CgminerApiClient::Miner` instances) | `request_id`, `direction`, `miner`, `payload` | `duration_ms` (response only — closure-computed delta from request `Time.now`), `bytes` (payload length) |

### `alert.*` (cgminer_monitor)


Opt-in per-miner threshold alerts. Wire-up: `CGMINER_MONITOR_ALERTS_ENABLED=true` plus a webhook URL and at least one of the three built-in rule thresholds (`ALERTS_HASHRATE_MIN_GHS`, `ALERTS_TEMPERATURE_MAX_C`, `ALERTS_OFFLINE_AFTER_SECONDS`) OR at least one composite rule (`CGMINER_MONITOR_ALERTS_COMPOSITE_*`, v1.4.0+). See the repo README for the full env matrix and composite-rule grammar.

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `alert.fired` | warn | `AlertEvaluator` | `miner`, `rule`, `threshold`, `observed`, `unit` | `details` (composite rules only — structured per-clause snapshot, see `details` standard-key) |
| `alert.resolved` | info | `AlertEvaluator` | `miner`, `rule`, `threshold`, `observed`, `unit` | `details` (composite rules only) |
| `alert.config_loaded` | info | `AlertEvaluator` (one per construction) | `built_in_rules`, `composite_rules` | |
| `alert.evaluation_complete` | info | `AlertEvaluator` (one per poll tick) | `duration_ms`, `rules_evaluated`, `fired_count`, `resolved_count` | |
| `alert.evaluator_error` | error | `Poller` (catches the evaluator) | `error`, `message`, `backtrace` | |
| `alert.state_write_failed` | error | `AlertEvaluator` | `miner`, `rule`, `error`, `message` | |
| `alert.suppressed_during_restart_window` | info | `AlertEvaluator` (offline rule + composites using offline_seconds) | `miner`, `rule` | |
| `alert.webhook_failed` | warn | `WebhookClient` | `miner`, `rule`, `error`, `message` | `status` (HTTP code on non-2xx responses) |

### `healthz.*` (cgminer_monitor)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `healthz.mongo_unreachable` | warn | `HttpApp` `/v2/healthz` | `error`, `message` | |

### `http.*` (both)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `http.request` | info | both `HttpApp` (after-filter) | `request_id`, `path`, `method`, `status`, `duration_ms` | |
| `http.500` | error | cgminer_manager `HttpApp` | `request_id`, `error`, `message`, `backtrace` | |
| `http.unhandled_error` | error | cgminer_monitor `HttpApp` | `request_id`, `error`, `message`, `backtrace` | |

### `migrate.*` (cgminer_monitor)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `migrate.complete` | info | `bin/cgminer_monitor migrate` | `message` | |

### `monitor.*` (cgminer_manager)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `monitor.call` | info | `MonitorClient` | `request_id`, `url`, `status`, `duration_ms` | |
| `monitor.call.failed` | warn | `MonitorClient` | `request_id`, `url`, `error`, `message` | |

### `mongo.*` (cgminer_monitor)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `mongo.write_failed` | error | `Poller` | `error`, `message` | |

### `poll.*` (cgminer_monitor)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `poll.complete` | info | `Poller` | `samples_written`, `snapshots_upserted`, `polls_ok`, `polls_failed` | |
| `poll.miner_failed` | warn | `Poller` | `miner`, `command`, `error` | `code` |
| `poll.unexpected_error` | error | `Poller` | `error`, `message`, `backtrace` | |

### `puma.*` (both)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `puma.crash` | error | both `Server#run` rescues | `error`, `message`, `backtrace` | |

### `rate_limit.*` (cgminer_manager)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `rate_limit.exceeded` | warn | `RateLimiter` | `request_id`, `remote_ip`, `path`, `retry_after` | |

### `reload.*` (both; `reload.partial` monitor-only)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `reload.signal_received` | info | both `Server` SIGHUP handlers | — | |
| `reload.ok` | info | both | `miners` | |
| `reload.failed` | warn | both | `error`, `message` | |
| `reload.partial` | error | cgminer_monitor `Server` only | `poller_ok`, `http_app_ok` | |

### `server.*` (both)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `server.start` | info | both `Server#run` | `pid`, `bind`, `port`, `log_format`, `log_level` | `mongo_url` (monitor only) |
| `server.stopping` | info | both | — | |
| `server.stopped` | info | both | — | |
| `server.crash` | error | cgminer_monitor `Server` | `error`, `message`, `backtrace` | |
| `server.pid_file_written` | info | both | `path` | |

### `startup.*` (cgminer_monitor)

| Event | Level | Emitter | Required keys | Optional |
|-------|-------|---------|---------------|----------|
| `startup.mongo_unreachable` | error | `Server` | `error`, `message` | |

## Evolution rules

This contract is pre-1.0 and not bound by SemVer; consumers should expect it to grow. Rules for additions and changes:

1. **Adding a new event** — pick an existing namespace or reserve a new one in this document (with repo ownership) before the first emit. Use existing standard keys where possible; new keys require a row in the standard-keys table above.
2. **Renaming an event or a key** — breaking change for log consumers. Land the rename with a `### Changed` CHANGELOG entry in the owning repo that explicitly names the old and new identifiers. Do not ship silent renames.
3. **Namespace ownership moves** — if a shared event becomes single-repo, or vice versa, update the namespace reservations section. The reverse (moving a single-repo namespace to shared) requires mirroring the event catalog entry across both repos' emit sites.
4. **Deprecation** — we don't emit both old and new names during a transition. Logs are low-cost to regenerate; dashboards are cheap to update. Pay the one-shot cost rather than carrying forever.
5. **Reserved words** — `ts`, `level`, `event` are injected by the `Logger` module; callers cannot override them. Adding another auto-injected key would affect every event in the catalog; don't.

## Grep recipes

Starting points for log consumers. Pipe stdout through `jq -c` first to get one JSON object per line.

Filter by namespace:
```
jq -c 'select(.event | startswith("admin."))' app.log
```

Filter by event + error class (triage a regression):
```
jq -c 'select(.event == "poll.miner_failed" and .error == "CgminerApiClient::ConnectionError")' app.log
```

Trace a single admin POST end-to-end:
```
jq -c 'select(.request_id == "a1b2c3d4-0000-0000-0000-000000000000")' app.log
```

Aggregate duration_ms p95 on a single event (requires `jq` + `awk` or a proper aggregator):
```
jq -c 'select(.event == "http.request") | .duration_ms' app.log \
  | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.95)]}'
```

## Out-of-contract

- Exception objects are never serialized directly — always `e.class.to_s` → `error` and `e.message` → `message`.
- Log values don't include the raw session id or the raw Basic-Auth credential; admin events carry `session_id_hash` + `user` (username) instead.
- `mongo_url` is always credential-redacted at the emit site; there is no code path that logs the raw connection string.
