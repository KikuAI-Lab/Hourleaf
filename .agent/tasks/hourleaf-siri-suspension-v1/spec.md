# Hourleaf Siri suspension fix

Class: temporary task artifact. GitHub Issue #3 owns the public task state; code and tests own the accepted behavior. Finalization keeps only the compact PASS evidence needed to audit the release fix.

## Goal

Prevent iOS from terminating Hourleaf after a successful Siri/App Intent write while preserving the exact persisted result and the existing local-first ledger.

## Acceptance criteria

- AC1: The physical build 16 failure is identified from a sanitized device crash receipt, including the termination class and its relationship to the Siri runs.
- AC2: Service and credit App Intents each persist exactly one requested minute value through the shared command path, then release persistence resources before suspension.
- AC3: A focused regression test fails for the unsafe lifecycle and passes for the corrected lifecycle without introducing another ledger writer or dependency.
- AC4: Focused tests, the relevant full test suite, Release build, and release guard pass from current source.
- AC5: A new signed TestFlight build on the same physical iPhone records one service and one credit entry with the exact prompt, and fresh crash-log comparison shows no new Hourleaf termination for either run.
- AC6: The two build 16 diagnostic entries and any final-canary entries are removed through Hourleaf's interface; read-only persistence comparison proves no unrelated active entry changed.

## Constraints

- Preserve the production bundle ID, App Group, Core Data model, user records, notes, settings, and Watch packaging.
- No new dependency, analytics, telemetry, direct database mutation, or destructive storage cleanup.
- Keep private ledger values, identifiers, device identifiers, and raw crash reports out of Git and GitHub.
- Do not attach or submit a build to App Store review until physical acceptance passes.

## Non-goals

- Redesign Siri phrasing, quick-entry UI, reporting rules, or CloudKit behavior.
- Treat a Siri confirmation dialog as persistence proof.
- Diagnose unrelated historical device crashes.

## Verification plan

1. Preserve a sanitized build 16 crash signature and exact before/after ledger deltas.
2. Add the smallest lifecycle fix and a focused regression test.
3. Run focused and full automated checks plus Release validation.
4. Archive/upload a new build only after local proof and the existing release gate are current.
5. Repeat both Siri actions on the physical device, compare the ledger and device crash logs, then remove canary entries through the UI and verify cleanup.
