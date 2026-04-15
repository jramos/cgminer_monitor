# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- Support for Ruby < 3.2. The gem now requires Ruby 3.2 or higher.
- `rails` runtime dependency. The gem no longer ships a Rails engine.
- `Mongoid.load!` at require time. Mongoid is now configured programmatically at startup.
- `pry` development dependency.

### Changed
- `cgminer_api_client` dependency bumped to `~> 0.3.0`.
- `mongoid` dependency bumped to `~> 9.0`.
- `Logger#log!` now unwraps `PoolResult` from cgminer_api_client 0.3.0 (was: raw Array from 0.2.x).
- Document writes use a single `save!` instead of three sequential `update_attribute` calls.
- Gemspec modernized: `required_ruby_version`, metadata URIs, `rubygems_mfa_required`, `Dir.glob` file list.

### Added
- `.ruby-version` file (development Ruby version).
- `.rubocop.yml` with project-tuned config.
- GitHub Actions CI matrix (Ruby 3.2, 3.3, 3.4, 4.0 best-effort, head best-effort).
- SimpleCov coverage tracking.
- `frozen_string_literal: true` on all Ruby files.
- Explicit `field :results` and `field :created_at` declarations on `Document::Log` for Mongoid 9 compatibility.
