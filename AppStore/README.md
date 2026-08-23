# Hourleaf App Store source

This directory is the maintained source for the Hourleaf 1.0.2 App Store
listing. Update it with every public release and copy the reviewed values into
App Store Connect only after the matching archive is verified.

## Product record

- Platform record: iOS with an embedded watchOS companion app
- App Store name: `Hourleaf: Ministry Hours`
- Bundle identifier: `com.kikuai.hourleaf`
- Version: `1.0.2` (`13`)
- Primary language: English (U.S.)
- Localizations: English (U.S.), Russian, Ukrainian
- Primary category: Productivity
- Secondary category: Utilities
- Price: Free
- Distribution: Public
- Copyright: `© 2026 KikuAI`
- Support URL: `https://kikuai.dev/hourleaf/support/`
- Marketing URL: `https://kikuai.dev/hourleaf/`
- Privacy policy URL: `https://kikuai.dev/hourleaf/privacy/`

Apple Watch metadata belongs to the same iOS App Store record. Upload Watch
screenshots in the Apple Watch section; do not create a second app record.
The reviewed screenshot order, dimensions, and privacy boundary are documented
in `screenshots/README.md`.

Post-upload, review, crash, and performance checks are documented in
[`release-monitoring.md`](release-monitoring.md). The runbook uses only Apple
first-party surfaces and does not add analytics or another SDK to Hourleaf.

`ExportOptions-AppStore.plist` is the reviewed automatic-signing export
configuration for the owner-controlled upload. It deliberately contains no
Team ID, Apple ID, password, API key, or other account material.

## Owner-only fields

App Review contact name, phone number, and email must be entered directly in
App Store Connect. Keep personal contact details out of this repository.

The final availability countries, release mode, and Digital Services Act
trader status are owner decisions made in App Store Connect before submission.
