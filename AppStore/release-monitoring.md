# Hourleaf release monitoring

Use this checklist after every upload and during the first week of a public
release. It intentionally relies on App Store Connect and Xcode Organizer only.
Hourleaf does not add analytics, crash-reporting SDKs, accounts, or telemetry.

## Keep the debugging artifacts

- Retain the submitted `.xcarchive` and its dSYMs until that build is no longer
  supported. Do not treat an archive as disposable Xcode cache.
- Record the public version, build number, archive path, submission state, and
  release date in the canonical Hourleaf GitHub Issue.
- Never commit an archive, provisioning profile, certificate, App Store Connect
  session, or user ledger to Git.

Apple references:

- [Acquire crash reports and diagnostic logs](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)
- [Diagnose issues using crash reports and device logs](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)
- [Build the app with debugging information](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information)

## Upload and review readback

For each candidate, verify in App Store Connect rather than inferring state from
an exported IPA:

1. The uploaded build finished processing and shows the expected iPhone app,
   embedded Apple Watch app, version, and build number.
2. The build is attached to the intended store version.
3. English, Russian, and Ukrainian release notes are saved.
4. App Review notes and contact fields are present without credentials or user
   data.
5. The version is actually submitted and the displayed review state is copied
   into the Issue.
6. After approval, confirm the configured release mode and then verify the
   public product page. A successful upload is not proof of submission,
   approval, release, or storefront availability.

## Crashes and hangs

Check Xcode **Window > Organizer > Crashes** for the released build after Apple
has enough opt-in diagnostic data, and again when a user reports a problem.
Also inspect the Organizer performance reports for hangs and regressions.

For each actionable group, record only:

- app version and build;
- iOS or watchOS version and device family;
- occurrence count and first/last observed dates;
- top symbolicated frame and affected Hourleaf feature;
- reproduction status and the regression test added with a fix.

Keep notes, ministry records, backup contents, device identifiers, contact
details, and full private logs out of public Issues. Store a private diagnostic
only when it is necessary, redact it first, and delete it when the investigation
ends.

Absence of an Organizer report does not prove that no crash happened: Apple
reports depend on user diagnostic sharing and provider processing. Do not add a
third-party SDK merely to turn that unknown into a marketing claim.

## Ratings and reviews

During the first release week, read App Store Connect ratings and reviews at
least twice, then check weekly while Hourleaf is actively maintained. Classify
feedback as one of:

- reproducible defect;
- clarity or accessibility problem;
- feature request;
- unsupported expectation;
- review that needs no product change.

Convert only concrete, reproducible work into the existing Hourleaf roadmap
Issue. Never reply as the user, promise a date, or disclose reviewer information
without a separate owner-approved response.

## Acquisition measurement

Use App Store Connect campaign links and aggregate storefront metrics only.
Hourleaf does not add an attribution SDK, device identifier, account, tracking
pixel, or per-user event log.

- Keep one campaign token per owned surface: `web-en`, `web-ru`, `web-uk`, and
  `github`.
- Generate the provider token in App Store Connect; never invent it. Read back
  each final URL before publishing it in the website or README.
- Record the public version, observation window, product-page views, first-time
  downloads, and conversion rate in the canonical Issue. A metric is unknown
  when Apple withholds a small cohort; do not infer zero or identify a person.
- Compare at least seven days of organic baseline with the same window after
  campaign links go live. Do not claim adoption from GitHub clones, CI traffic,
  an upload, an approval, or a single owner installation.
- Paid ads, creator outreach, and community posting require their own bounded
  owner decision; they are not part of the default release process.

## Release closeout

A release is closed only when the canonical Issue contains provider readback
for upload, processing, submission, Apple decision, configured release mode,
and public availability, plus the exact test and archive evidence. Keep any
physical-device or iCloud checks explicitly marked as owner gates until they
have their own fresh evidence.
