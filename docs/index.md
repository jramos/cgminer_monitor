# Knowledge Base Index — `cgminer_monitor`

**This file is the entry point for AI assistants working on `cgminer_monitor`.** It summarizes every other document in `docs/` so an assistant can pull in only the file(s) relevant to a given question. When no single file is an obvious fit, read `AGENTS.md` (consolidated, at repo root) or skim `codebase_info.md` first.

## How to use this index

1. **Identify the question category** from the table below (Architecture? HTTP API? Data model? Operational concern?).
2. **Read the mapped file.** Each mapping includes a one-line "use this when" hook plus a brief summary below.
3. **Cross-reference** via the explicit links between documents — they're maintained.
4. **Fall back** to reading the code. All docs are derived from `lib/`, `bin/`, and `spec/`; if a doc and the code disagree, the code is truth and the doc is stale (please flag it).

## Question → file map

| If the question is about... | Start here |
|---|---|
| "what is this project?" / stack / file tree / module graph | [`codebase_info.md`](codebase_info.md) |
| two-thread execution model / signal-handler dance / graceful shutdown / why things are shaped this way | [`architecture.md`](architecture.md) |
| what each class/module does / responsibilities / where to find X | [`components.md`](components.md) |
| HTTP API contracts / CLI exit codes / env-var table / `miners.yml` schema / structured-log schema | [`interfaces.md`](interfaces.md) |
| MongoDB collection shapes / `Sample`/`Snapshot` fields / `Config` invariants / error hierarchy | [`data_models.md`](data_models.md) |
| startup / polling loop / HTTP request lifecycle / test harness / release process | [`workflows.md`](workflows.md) |
| runtime + dev deps / Ruby + Mongo version floors / CI matrix | [`dependencies.md`](dependencies.md) |
| known gaps, inconsistencies, caveats in the docs themselves / cleanup recommendations | [`review_notes.md`](review_notes.md) |

## Document summaries

### [`codebase_info.md`](codebase_info.md)
**Purpose:** The one-pager. What cgminer_monitor is (a standalone daemon, not a Rails engine anymore as of 1.0), what Ruby/Mongo versions it supports, the full file tree, and a high-level module graph. **Start here if you've never seen the project.**

### [`architecture.md`](architecture.md)
**Purpose:** Why the code is shaped the way it is. Covers: the two-thread model (Poller + Puma), the signal-handler reinstall dance around Puma's `setup_signals`, graceful shutdown via a `Queue` + `ConditionVariable`, the read-path vs write-path decoupling via Mongo, `Config`-as-Data.define immutability, OpenAPI as source of truth. **Read this before making non-trivial structural changes.**

### [`components.md`](components.md)
**Purpose:** Catalog of every file in `lib/` (and the two test-only helpers). Each entry lists responsibilities, key public methods, and what calls into it. Includes the CLI subcommand table with exit codes. **Read this to find where a specific piece of behavior lives.**

### [`interfaces.md`](interfaces.md)
**Purpose:** Exhaustive contract reference. CLI (subcommands, exit codes, stdout/stderr contract). Env-var config table. `miners.yml` schema. Full HTTP API contract (every endpoint, every query parameter, every response shape, every error code). Structured-log event schema. Upstream dependencies (`cgminer_api_client`, MongoDB). **Read this for API/CLI/config questions.**

### [`data_models.md`](data_models.md)
**Purpose:** Runtime data. MongoDB collection shapes for `samples` (time-series) and `latest_snapshot` (regular) — fields, indexes, TTL. `Config` value object invariants. `Sample`/`Snapshot` Mongoid model specifics (why `store_in` is programmatic for `Sample`). Error class hierarchy. Raw vs. stored cgminer response shape. **Read this for "what's in the database" or "what fields does X have."**

### [`workflows.md`](workflows.md)
**Purpose:** Sequence diagrams and step-by-step flows. Startup, polling, request handling, graceful shutdown. Dev test workflow (unit, integration, openapi-check). Docker Compose dev stack. Release process. **Read this to understand how code paths compose over time.**

### [`dependencies.md`](dependencies.md)
**Purpose:** Runtime deps (cgminer_api_client, mongoid, sinatra, puma, rack-cors) and dev deps. Ruby/Mongo version rationale. CI matrix (lint/test/integration/openapi-check jobs). Mongoid 9 ↔ BSON 6 constraint. **Read this for "can I add gem X?", "what Rubies does this support?", or "why is Mongoid pinned."**

### [`review_notes.md`](review_notes.md)
**Purpose:** Self-audit. Consistency checks across other docs. Known gaps where the code is fuzzy (e.g., `DEBUG` env var documented but unwired, `StorageError`/`PollError` declared but unused, class-attr shadowing on Server/HttpApp). Cleanup recommendations with effort/value triage. **Read this before trusting a confident-sounding claim elsewhere in these docs.**

## Example queries and where to go

| Query | Primary file(s) |
|---|---|
| "How do I add a new HTTP endpoint?" | `components.md` (HttpApp) + `architecture.md` (OpenAPI enforcement) + `workflows.md` (openapi consistency check) + the root `AGENTS.md` for the exact step list |
| "How do I add a new extracted metric?" | `components.md` (`Poller#extract_samples`) + `data_models.md` (sample meta shape) |
| "What happens if Mongo goes away mid-poll?" | `architecture.md` (Poller error handling) + `workflows.md` (polling flow) + `interfaces.md` (Logger event names) |
| "What's the CLI exit code when…?" | `interfaces.md` (CLI table) + `components.md` (bin/cgminer_monitor) |
| "Why is `Server.started_at` read from `HttpApp.started_at`?" | `architecture.md` (class-level state pattern) + `review_notes.md` (gap #3) |
| "Can I run this with MongoDB 4.4?" | `dependencies.md` (Mongo version support) — no, time-series requires 5.0+ |
| "What's the schema of the `/v2/graph_data/hashrate` response?" | `interfaces.md` (HTTP API → Graph data) |
| "Where does cgminer's `\"Pool Rejected%\"` end up in Mongo?" | `data_models.md` (Sample meta shape) — `metric: "pool_rejected_pct"` |

## Maintenance note

These docs were generated by analyzing the 1.0.0 source. They reflect the state at that release. When the code changes substantially:

- Prefer updating the specific file that contains the affected claim (smaller diffs, clearer history).
- Update `review_notes.md` if you find a new inconsistency or gap.
- Re-run the codebase-summary skill in `update_mode=true` if the surface area has shifted enough to warrant a re-analysis.

If you're an AI assistant and you find a doc that contradicts the current code, **trust the code** and flag the discrepancy to the maintainer rather than silently fixing the doc.
