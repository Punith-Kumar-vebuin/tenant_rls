# Changelog

All notable changes to the `tenant_rls` gem are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.2] - 2026-06-16

### Fixed

- **Restored hash-based worker args support** in
  `JobContextResolver#extract_tenant_from_worker_args`. The optimized rewrite
  only handled `Array` perform args and silently dropped support for a `Hash`
  passed as `worker_perform_args` (e.g. `{ company_id: 789 }`). This was a
  backward-compatibility regression and is now handled again.
- **Made `ThreadContextManager#capture_current_context` dependency-free.** It
  used `Time.zone.now`, which raises when `Time.zone` is not configured and
  returns an `ActiveSupport::TimeWithZone` (not a `Time`). It now uses
  `Time.now`, which is always a `Time` and requires no ActiveSupport zone setup.

### Tests

- Updated the spec suite to match the current `lib/` behaviour (all green):
  - `configuration_spec`: `valid_strategies` now expects `:hybrid`.
  - `job_context_integration_spec`: aligned the "no tenant data" expectation
    with debug-only logging, corrected the legacy `tenant_from_job_data` log
    regex, and stubbed `connection.quote` on the test double.
  - `thread_context_manager_spec`: stubbed `ApplicationRecord`, replaced
    `Time.current` with `Time.now`, and removed tests for methods the
    simplified `ThreadContextManager` no longer exposes
    (`with_tenant_context`, `with_tenant_context_and_connection`,
    `create_context_aware_thread`).

## [0.2.1] - 2026-06-16

### Security / Dependencies (no runtime logic changes)

This is a **maintenance release**. No gem logic, public API, or strategy
behaviour was changed. Only dependency metadata and the development lockfile
were updated to clear AWS Inspector "Critical" findings. See
[SECURITY_CVE_REVIEW.md](SECURITY_CVE_REVIEW.md) for the full analysis and the
upgrade guide for consuming services.

- Added `required_ruby_version = '>= 2.3.0'` to `tenant_rls.gemspec`. This only
  documents the supported floor; it was deliberately kept at 2.3 so existing
  production services still on Ruby 2.3.x can continue to install the gem.
- Refreshed the gem's own `Gemfile.lock` (development/CI only) to patched
  transitive versions:
  - `nokogiri` 1.18.8 -> 1.19.3 (GHSA-353f-x4gh-cqq8)
  - `net-imap` 0.5.9 -> 0.6.4.1 (CVE-2026-42257, CVE-2026-42258)
  - `rack-session` 2.1.1 -> 2.1.2 (CVE-2026-39324)
  - `rails` 8.0.2 -> 8.1.3 (2026 ActiveStorage CVEs: CVE-2026-33202, CVE-2026-33195)

### Notes

- The gemspec runtime dependencies were intentionally **not** floored upward
  (`rails >= 4.0`, `activesupport >= 4.0`, `concurrent-ruby ~> 1.2`). Raising
  them would break the Ruby 2.3.x services. The gem does not, and cannot,
  enforce these security patches on consumers — each host application resolves
  and patches these gems in its own `Gemfile.lock`.

## [0.2.0]

- Documented `TenantThread` and the `:hybrid`-oriented resolution narrative in
  the README. (Version metadata in `lib/tenant_rls/version.rb` was not bumped at
  the time; `0.2.1` reconciles the version number.)

## [0.1.0]

- Initial release.
- PostgreSQL RLS integration.
- Tenant resolution strategies: `:warden`, `:custom_auth`, `:job_context`, `:manual`.
- Background job support (Sidekiq worker patch and ActiveJob `around_perform`).
- Thread-safe design with `Concurrent::ThreadLocalVar`.
- Rails controller and model integration.

[0.2.2]: #022---2026-06-16
[0.2.1]: #021---2026-06-16
[0.2.0]: #020
[0.1.0]: #010
