# Hourleaf 1.0.2 UX release evidence

Canonical state: `KikuAI-Lab/Hourleaf#3`.

## Source and behavior

- Release-candidate baseline: unit tests PASS, 504 of 504; full iPhone UI
  suite PASS, 52 of 52.
- Portable-contract focused tests: PASS, 31 of 31 (backup 18, monthly report
  7, service year and formatter 6).
- Fresh post-contract GitHub CI: PENDING on the first `main` run.
- The compact Add regression verifies that the complete Bible-study control is
  visible without an initial scroll at the default text size.
- Light appearance persistence, accessibility text sizes, Reduce Motion,
  English/Russian/Ukrainian Settings, history, reports, reminders, backup, and
  the existing ledger workflows remain covered by the passing suite.
- Release-readiness guard and its mutation self-test: PASS.
- `git diff --check`: PASS.

A local full-suite diagnostic compiled all targets and completed 506 of 507
unit tests. Its only assertion failure was a locale-dependent English string
expectation while the canonical simulator was configured for Russian; the test
now pins English explicitly. The App Store screenshot UI test passed, then an
independent repository started another Xcode run on the one shared simulator
and killed the next UI runner. This is recorded as simulator contention, not as
product acceptance; the isolated GitHub runner owns the final post-change gate.

## Package

- Retained archive: `Hourleaf 1.0.2 (13).xcarchive`.
- App Store distribution export: PASS. The exported `Hourleaf.ipa` contains
  production distribution profiles with `get-task-allow` disabled and no
  provisioned-device list.
- iPhone app, Quick Surfaces extension, and Apple Watch app all read back as
  `1.0.2 (13)`.
- Production bundle identifiers and App Group entitlements, nested signature
  verification, three privacy manifests, EN/RU/UK localizations, compiled app
  assets, and the host dSYM: PASS.

## Public guide

- English: `https://kikuai.dev/hourleaf/guide/` — HTTP 200.
- Russian: `https://kikuai.dev/hourleaf/guide/ru/` — HTTP 200.
- Ukrainian: `https://kikuai.dev/hourleaf/guide/uk/` — HTTP 200.
- The complete site gate passed 282 of 282 tests; responsive browser QA found
  zero console errors.

## Remaining provider gate

The verified distribution IPA is ready. The first upload attempt stopped before
network transfer because Xcode has no Apple Account configured and therefore
cannot find App Store Connect access for team `Kiku Reise`. The remaining work
is owner-local Xcode sign-in, upload, processing readback, App Store version
attachment, and submission.

Provider readback on 2026-08-23 shows public version `1.0.1` (build 12),
automatic release configured, 175 territories selected, and public storefront
availability in the United States, Lithuania, and Ukraine. Build 13 is not
claimed as uploaded or submitted.
