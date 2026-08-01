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
  historical daily entries.

## Delivery gates

- Apple Developer signing, App ID and iCloud container registration, CloudKit
  production-schema promotion, App Store Connect creation, and 2FA require the
  repository owner's Apple account.
- Opening a share sheet is not proof of delivery. A report is recorded as sent
  only after an explicit user confirmation.

## Verification snapshot — 2026-08-01

- `xcodebuild ... test`: 14 unit/integration and 5 UI tests passed on iPhone 17
  Pro Simulator (iOS 26.5).
- Unsigned generic-device Release build passed with Xcode 26.6 and Swift 6.3.3.
- Manual visual smoke passed in light, dark, and accessibility text sizes.
- Real-device CloudKit mirroring and TestFlight remain unverified until the
  Apple Developer owner gates above are completed.
