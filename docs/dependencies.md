# Dependencies

## Runtime dependencies

From the gemspec:

| Gem | Constraint | Purpose |
|---|---|---|
| `cgminer_api_client` | `~> 0.3.0` | Talks to cgminer over its JSON API. Used by `Poller` for the parallel fan-out and in `bin/cgminer_monitor doctor` for connectivity pings. |
| `mongoid` | `~> 9.0` | MongoDB ODM. Configures the `default` client from `CGMINER_MONITOR_MONGO_URL`. Backs `Sample` and `Snapshot`. |
| `sinatra` | `>= 4.0` | HTTP app framework. `HttpApp < Sinatra::Base`. |
| `puma` | `>= 6.0` | HTTP server. Embedded via `Puma::Configuration` + `Puma::Launcher`. |
| `rack-cors` | `~> 2.0` | CORS middleware. Configured from `CGMINER_MONITOR_CORS_ORIGINS`. |

Plus the Ruby stdlib pieces: `json`, `socket`, `yaml`, `cgi/escape`, `time`, `net/http` + `uri` (used by `WebhookClient` so the alerts feature adds no runtime gem dependency).

**One conditional dependency.** `Gemfile` adds `gem 'ostruct' if RUBY_VERSION >= '3.5'` because Ruby 4.0 moved `ostruct` out of default gems and Mongoid 9 hasn't caught up yet. This is a compatibility shim, not a feature dep — `ostruct` is used by Mongoid internals, not by our code.

**Transitive deps worth knowing about.** Mongoid pulls in `mongo` (the BSON driver) and `bson`. Sinatra pulls in `rack` and `tilt`. Puma pulls in `nio4r`. None of these are used directly by our code.

## Dev dependencies

From `Gemfile`:

```ruby
group :development do
  gem 'rack-test',     '>= 2.1'
  gem 'rake',          '>= 13.2'
  gem 'rspec',         '>= 3.13'
  gem 'rubocop',       '>= 1.60'
  gem 'rubocop-rake',  '>= 0.6'
  gem 'rubocop-rspec', '>= 3.0'
  gem 'simplecov',     '>= 0.22'
  gem 'webmock',       '>= 3.24'
end
```

| Gem | Used for |
|---|---|
| `rack-test` | HTTP app specs — provides `Rack::Test::Methods` for making synthetic requests against `HttpApp` without spinning up Puma. |
| `rake` | Task runner. `Rakefile` defines `default: [spec, rubocop]` and `test: :spec`. |
| `rspec` | Test framework. Unit + integration. |
| `rubocop` | Linter. `.rubocop.yml` has `TargetRubyVersion: 3.2` and turns off most `Metrics/*` cops. |
| `rubocop-rake` / `rubocop-rspec` | RuboCop plugin cops for Rake and RSpec styles. |
| `simplecov` | Code coverage. Starts in `spec_helper.rb`. |
| `webmock` | Stubs `Net::HTTP` in the alerts integration spec and the webhook-client unit spec. Loaded *only* inside those specs via a scoped `require 'webmock/rspec'` — the CLI reload integration spec depends on real local HTTP and must not be affected. |

## Ruby version support

- **Minimum: Ruby 3.2.** Enforced by `spec.required_ruby_version = ">= 3.2"`. Data.define (used by `Config`) requires 3.2+.
- **CI-tested: 3.2, 3.3, 3.4.** Must-pass.
- **Best-effort: 4.0, head.** Allowed to fail in CI (`continue-on-error`). Mongoid 9 upstream only officially tests 3.3, so 3.4 parity is our assertion not theirs; 4.0 is even more speculative.
- **Local dev pin:** `.ruby-version` (not shown here but present).

**Why not higher floor?** Mongoid 9 supports Ruby 3.0+, `cgminer_api_client` requires 3.2+, `Data.define` requires 3.2+. 3.2 is the tightest floor that doesn't give up features we use.

**Compatibility gotchas the CI matrix proves:**
- Ruby 3.4's `ostruct` deprecation warnings hit Mongoid 9 internals. The Gemfile pins `ostruct` when `RUBY_VERSION >= '3.5'`; earlier 3.4 deprecation warnings are tolerated in the CLI integration spec.
- Ruby 4.0's default-gem removal of `ostruct` is handled by the same `ostruct` pin.

## MongoDB version support

- **Minimum: MongoDB 5.0.** Required for time-series collections (the `samples` collection uses `timeField`/`metaField`/`granularity`/`expire_after` all of which are 5.0+ features).
- **CI-tested: 6.0 and 7.0.** 6.0 is the earliest Mongo image available in GitHub Actions `services:`.
- The floor claim for 5.0 is **asserted** but not tested in CI directly. A regression that broke 5.0 but not 6.0 wouldn't be caught automatically.

Mongo driver (`mongo`, pulled in transitively by `mongoid`) is constrained by Mongoid 9 to `bson < 6`. When `bson 6` ships, cgminer_monitor can't upgrade until Mongoid 10 lands and we bump the constraint.

## CI matrix (`.github/workflows/ci.yml`)

Four jobs:

### `lint`
- Runs RuboCop on Ruby 3.4.
- Separate job so rubocop failures don't block test results for other Ruby versions.

### `test`
- Matrix: Ruby 3.2/3.3/3.4 × Mongo 7, plus Ruby 3.4 × Mongo 6 (for Mongo version coverage), Ruby 4.0 × Mongo 7 (experimental), Ruby head × Mongo 7 (experimental).
- Runs `bundle exec rspec --exclude-pattern 'spec/integration/**/*_spec.rb'`. Integration specs are slower, so they run on their own job below.
- Mongo comes from `services: mongo: image: mongo:<v>`.

### `integration`
- Runs on Ruby 3.4 × Mongo 7 only. One matrix cell.
- Runs `bundle exec rspec spec/integration/ -fd` (documentation formatter for readability).

### `openapi-check`
- Runs on Ruby 3.4 × Mongo 7.
- Runs `bundle exec rspec spec/openapi_consistency_spec.rb -fd`.
- Separate job so openapi drift is a distinct red signal from test failures.

All jobs use `ruby/setup-ruby@v1` with `bundler-cache: true` for gem caching between runs.

Triggers: `push` and `pull_request` on `master` or `develop`.

## External dependencies (not Ruby gems)

- **cgminer itself** — the gem queries cgminer's JSON API. The fixture file at `spec/support/cgminer_fixtures.rb` (shared with `cgminer_api_client`) is grounded in cgminer 4.11.1's `codes[]` table from `cgminer/api.c`. The wire format has been stable for years.
- **MongoDB** — runtime only. See above for version support.
- **Docker** (optional but recommended for dev) — a `Dockerfile` and `docker-compose.yml` are provided.

## Dependency update strategy

No Dependabot or Renovate configured. Manual bumps when breakage is reported or when picking up wanted features. Minimum version constraints are intentionally permissive-above-a-floor (`rspec >= 3.13`, `puma >= 6.0`, etc.) so `bundle install` resolves current versions without over-constraining downstream lockfiles.

Consumers: `Gemfile.lock` is **not** committed (per gem convention). Operators installing the gem generate their own.
