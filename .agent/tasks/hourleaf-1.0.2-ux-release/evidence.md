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

## Provider submission

- On 2026-08-23 at 18:42 Europe/Uzhgorod, `xcodebuild -exportArchive`
  completed App Store Connect analysis and upload with `Upload succeeded`,
  `Uploaded package is processing`, and `** EXPORT SUCCEEDED **`.
- App Store Connect finished processing the package. Its build picker showed
  build `13`, version `1.0.2`; the attached assets included the iPhone app and
  embedded Apple Watch app.
- Version `1.0.2` was created on the existing app record, build `13` was
  attached, and the canonical English, Russian, and Ukrainian release notes
  from `AppStore/metadata` were saved. Existing automatic release and the
  provider metadata passed the submission validation.
- At 18:55 Europe/Uzhgorod, App Store Connect displayed `1 Item Submitted` for
  `iOS App 1.0.2` / `1.0.2 (13)`. The durable provider state readback is
  `Waiting for Review`.
- No physical iPhone or Apple Watch was installed, mirrored, or controlled
  during upload or submission.

The public App Store lookup still returned `1.0.1` in the United States,
Lithuania, and Ukraine at submission time. That is expected until Apple makes a
review decision and the configured automatic release completes; approval and
public `1.0.2` availability are not claimed by this receipt.
