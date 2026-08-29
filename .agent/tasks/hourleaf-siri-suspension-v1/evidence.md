# Evidence

## Current verdict

PASS. AC1 through AC5 have current PASS evidence. The owner explicitly waived
AC6 cleanup and chose to retain the diagnostic and canary entries, so no ledger
deletion or direct database mutation was performed.

## AC1 — PASS: physical failure identified

- Both build 16 Siri actions persisted the exact requested service and credit
  entries through the shortcut source.
- Each action was followed by its own `RUNNINGBOARD` `0xdead10cc` termination.
- Matching dSYM symbolication placed both terminations in the host app's shared
  quick-surface file lock during post-persistence reconciliation.
- See `raw/build16-diagnosis.md`.

## AC2 — PASS: exact write and balanced resource lifetime

- Existing App Intent tests prove service and credit remain separate and each
  writes exactly once through the shared command path.
- Production host reconciliation now begins one UIKit background assertion
  before shared-file access and ends it after successful or failed readback.
- Dedicated tests cover normal completion, expiration before activation,
  expiration after activation, an invalid task grant, and sidecar failure.

## AC3 — PASS: focused regression contract

- The injected execution-activity spy observes the sidecar publish while the
  activity is active and verifies exactly one begin/end pair.
- The same balance is enforced on the error path. Removing the wrapper makes
  these assertions fail without changing the ledger or adding a writer.
- Focused result: 38 of 38 PASS; see `raw/focused-tests-summary.json`.

## AC4 — PASS: automated and package safety

- Full unit/integration result: 523 of 523 PASS.
- App-owned non-screenshot UI result: 53 of 53 PASS.
- Release guard, guard self-test, unsigned Release build, embedded extension
  and Watch validation, privacy manifests, App Intents metadata, and dSYM all
  pass for `1.0.4 (17)`.
- See `raw/full-unit-summary.json`, `raw/ui-summary.json`, and
  `raw/release17-package.md`.

## AC5 — PASS: physical build 17 acceptance

- TestFlight updated the same physical iPhone from build 16 to build 17 without
  changing any existing ledger row.
- The production Siri actions asked for minutes and persisted exactly one
  requested service entry and one requested credit entry through the shortcut
  source.
- A fresh system crash-log comparison after both actions contained no new
  Hourleaf crash file and therefore no new `0xdead10cc` termination.
- See `raw/build17-physical-acceptance.md`.

## AC6 — WAIVED: diagnostic entries retained

- On 2026-08-29 the owner explicitly chose to retain the build 16 diagnostic
  entries and build 17 canaries.
- No cleanup mutation was performed. The read-only physical comparison already
  proved that the TestFlight update and both build 17 Siri actions changed no
  pre-existing ledger row.
