# Evidence

Verified on 2026-08-13 against the task-owned working tree.

## Product behavior

- `RootView` no longer presents an onboarding cover.
- `OnboardingView.swift` and its user-facing EN/RU/UK copy are removed.
- Fresh-install launch still initializes the normal model and opens Quick Entry.
- Legacy Core Data and portable-backup fields were intentionally left intact.

## Checks

- Localization plist lint and exact EN/RU/UK key parity: PASS (367 keys each).
- Static scan for shipped onboarding source/copy and the old UI-test argument:
  PASS; only negative UI assertions remain.
- Fresh-install UI acceptance on the canonical iPhone 17 simulator: PASS,
  2/2 tests, including Accessibility XXXL.
- Backup and local-bundle migration compatibility: PASS, 17/17 tests.
- Full `HourleafTests` suite: PASS, 486/486 tests.
- `scripts/verify-release-readiness.sh`: PASS.
- `scripts/test-verify-release-readiness.sh`: PASS.
- Unsigned generic Release build of the iPhone app, Quick Surfaces extension,
  and Watch app: PASS.
- `git diff --check`: PASS.

## Release boundary

The Xcode build number is 2 for the app, Quick Surfaces extension, and Watch
app. Upload, TestFlight installation, data restore, and physical-device
acceptance remain separate release actions owned by GitHub Issue #3.
