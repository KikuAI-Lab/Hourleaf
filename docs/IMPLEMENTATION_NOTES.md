# Hourleaf implementation notes

Class: temporary task artifact. The canonical task surface is
KikuAI-Lab/Hourleaf#1. Delete or reduce this file to durable follow-ups when the
MVP is accepted.

## Decisions

- Native SwiftUI, Core Data, CloudKit, and UserNotifications are used without
  third-party dependencies.
- Reporting totals and service-year progress are separate calculations. A
  carried minute can affect a report but never changes the date on which the
  underlying service occurred.
- Service and credit time use the same reporting policy but maintain separate
  carry balances. Credit time never contributes to the 600-hour goal.
- CloudKit is an adapter behind the repository boundary, not the domain model.
  Android or self-hosted sync will require a future backend and migration, but
  not a rewrite of reporting rules.
- Opening balances let a person adopt Hourleaf mid-year without manufacturing
  historical daily entries. The 600-hour goal never caps the saved opening
  progress; opening hours use direct non-negative numeric input.
- Reporting remainders never cross the service-year boundary from August into
  September. The legacy Core Data flag remains only for store compatibility and
  is ignored by domain calculations.
- Personal Team testing uses a separate `com.kikuai.hourleaf.local` bundle ID
  and a compile-time local-only store. The installer edits target capabilities
  only in a temporary project copy; it does not claim or alter the future App
  Store bundle ID and does not pretend to verify CloudKit sync. Records created
  under this local bundle ID will not migrate automatically to the future App
  Store sandbox.

## Delivery gates

- Apple Developer signing, App ID and iCloud container registration, CloudKit
  production-schema promotion, App Store Connect creation, and 2FA require the
  repository owner's Apple account.
- Opening a share sheet is not proof of delivery. A report is recorded as sent
  only after an explicit user confirmation. Closing the share sheet always
  opens that confirmation, including when sharing was cancelled.
- Report navigation stops at the configured ledger start, so Hourleaf never
  presents or snapshots invented months before the user's opening balances.

## Verification snapshot — 2026-08-02

- `xcodebuild ... test`: 15 unit/integration and 12 UI tests passed on iPhone 17
  Pro Simulator (iOS 26.5). UI coverage includes past-date entry, editing,
  deletion, reminders, ledger-start report navigation, and share cancellation.
- Unsigned generic-device Release build and Xcode Analyze passed with Xcode
  26.6 and Swift 6.3.3.
- Manual visual smoke passed in light, dark, and accessibility text sizes.
- The Personal Team installer built, signed, installed, and launched the
  local-only app on a physical iPhone. The latest in-place update reopened the
  existing store with its service and credit entries intact; quick entry,
  history, progress, and settings were read back through iPhone Mirroring.
- CloudKit mirroring and TestFlight remain deferred by the owner's decision to
  test locally without an Apple Developer Program membership.
