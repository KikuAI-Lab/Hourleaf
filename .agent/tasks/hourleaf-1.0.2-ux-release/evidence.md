# Hourleaf 1.0.2 UX release evidence

Canonical state: `KikuAI-Lab/Hourleaf#3`.

## Source and behavior

- Unit tests: PASS, 504 of 504.
- Full iPhone UI suite: PASS, 52 of 52.
- The compact Add regression verifies that the complete Bible-study control is
  visible without an initial scroll at the default text size.
- Light appearance persistence, accessibility text sizes, Reduce Motion,
  English/Russian/Ukrainian Settings, history, reports, reminders, backup, and
  the existing ledger workflows remain covered by the passing suite.
- Release-readiness guard and its mutation self-test: PASS.
- `git diff --check`: PASS.

## Package

- Retained archive: `Hourleaf 1.0.2 (13).xcarchive`.
- iPhone app, Quick Surfaces extension, and Apple Watch app all read back as
  `1.0.2 (13)`.
- Nested signature verification, three privacy manifests, EN/RU/UK
  localizations, compiled app assets, and the host dSYM: PASS.

## Public guide

- English: `https://kikuai.dev/hourleaf/guide/` — HTTP 200.
- Russian: `https://kikuai.dev/hourleaf/guide/ru/` — HTTP 200.
- The complete site gate passed 282 of 282 tests; responsive browser QA found
  zero console errors.

## Review finding and remaining gate

Adversarial review found that production entitlements must be verified from the
exported App Store package, not inferred from the development-signed archive.
The first local export was stopped without upload while the Mac was locked at
the Apple Distribution key prompt. The remaining work is owner-local prompt
approval, IPA entitlement verification, upload, processing readback, App Store
version attachment, and submission.
