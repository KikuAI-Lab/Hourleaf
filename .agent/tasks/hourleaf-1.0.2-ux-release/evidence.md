# Hourleaf 1.0.2 UX release evidence

Canonical state: `KikuAI-Lab/Hourleaf#3`.

## Source and behavior

- Final isolated GitHub CI passed at
  `https://github.com/KikuAI-Lab/Hourleaf/actions/runs/32631131958`: 507 of
  507 unit tests and 52 of 52 app-owned iPhone UI tests, plus the release guard
  and its mutation self-test.
- Portable-contract focused tests: PASS, 31 of 31 (backup 18, monthly report
  7, service year and formatter 6).
- The manual App Store capture lane passed 1 of 1 locally on the canonical
  iPhone 17 / iOS 26.5 simulator and retained all 12 EN/RU/UK attachments.
  Standard CI excludes this artifact-producing lane and runs the 52 stable
  application UI regressions instead.
- The compact Add regression verifies that the complete Bible-study control is
  visible without an initial scroll at the default text size.
- Light appearance persistence, accessibility text sizes, Reduce Motion,
  English/Russian/Ukrainian Settings, history, reports, reminders, backup, and
  the existing ledger workflows remain covered by the passing suite.
- Release-readiness guard and its mutation self-test: PASS.
- `git diff --check`: PASS.
- The versioned report/service-year JSON and canonical password-free backup
  fixture are documented in `Contracts/` and consumed by Swift tests for future
  Android parity without coupling another platform to Swift implementation.
- `AppStore/release-monitoring.md` defines an Apple-only crash, hang, review,
  and release-readback routine without adding telemetry or a third-party SDK.
- No physical iPhone or Apple Watch was installed, mirrored, or controlled in
  this stabilization pass.

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
- Cloudflare Pages deployment `49bb9bbb-0dd2-4196-8a1c-2d204c1e33ca`
  completed successfully.

## Remaining provider gate

The verified distribution IPA is ready. A fresh upload attempt after the green
CI run stopped before network transfer on 2026-08-23 at 13:02 Europe/Uzhgorod:
`xcodebuild` exited 70 with `Failed to Use Accounts`. Xcode therefore has no
usable Apple Account for App Store Connect. The remaining work is owner-local
Xcode sign-in, upload, processing readback, App Store version attachment, and
submission.

Provider readback on 2026-08-23 shows public version `1.0.1` (build 12),
automatic release configured, 175 territories selected, and public storefront
availability in the United States, Lithuania, and Ukraine. Build 13 is not
claimed as uploaded or submitted.
