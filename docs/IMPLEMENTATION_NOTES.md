# Hourleaf implementation notes

Class: temporary task artifact. The canonical task surface is
KikuAI-Lab/Hourleaf#3. Delete or reduce this file to durable follow-ups when the
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
- Settings use plain-language examples for reporting rules, clearly identify
  editable report wording, and present storage as status rather than a choice.
  Developer links replace internal App Store metadata.
- App, Shortcuts, and future quick surfaces share one validated mutation
  contract. Stable mutation IDs make exact retries idempotent, while captured
  revisions prevent an older screen from overwriting a newer edit.
- Deleting a time entry is reversible: it moves to Recently Deleted, immediately
  leaves totals, and can be restored. Until verified backup and restore ship,
  Hourleaf keeps every deleted entry accessible instead of promising or running
  a 30-day purge.
- Every entry change appends an immutable revision. Foreground changes expose a
  short Undo banner, and the latest eligible change remains undoable for ten
  minutes when it has not been superseded.
- Hourleaf promotes exactly three system commands: Add Service, Add Credit, and
  Open Add Time. Record commands use the same validated repository actor as the
  app; opening the form and tapping a reminder only route to a blank quick-entry
  draft and never create time automatically.

## Delivery gates

- Apple Developer signing, App ID and iCloud container registration, CloudKit
  production-schema promotion, App Store Connect creation, and 2FA require the
  repository owner's Apple account.
- Opening a share sheet is not proof of delivery. A report is recorded as sent
  only after an explicit user confirmation. Closing the share sheet always
  opens that confirmation, including when sharing was cancelled.
- Report navigation stops at the configured ledger start, so Hourleaf never
  presents or snapshots invented months before the user's opening balances.
- A zero-duration history edit is treated as an intent to remove an accidental
  entry. Hourleaf asks for confirmation and deletes it instead of storing a
  meaningless zero-minute record or showing a validation dead end.

## Verification snapshot — 2026-08-02

- `xcodebuild ... test`: 15 unit/integration and 13 UI tests passed on iPhone 17
  Simulator (iOS 26.5). UI coverage includes past-date entry, editing,
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

## Verification snapshot — 2026-08-03 (roadmap Slice 2)

- 58 unit/integration tests and 16 UI tests passed on the iOS 26.5 simulator.
  Coverage includes strict dates and duration bounds, idempotent replay,
  optimistic revisions, all four Undo inverses, the exact ten-minute boundary,
  soft delete/restore, report fingerprints, zero-duration deletion, VoiceOver,
  and accessibility text size.
- Unsigned Debug and Release builds passed; `git diff --check` is clean.
- The V1/V2 model files, current-version marker, managed-object declarations,
  entitlements, privacy manifest, and Xcode project remain unchanged.
- A Sol Max adversarial re-review returned GO with no P0 or P1 findings. Full
  revision-graph validation and a two-repository concurrency harness remain
  mandatory before multi-process or CloudKit writers are enabled.
- This slice was not installed on the physical iPhone. Device data remains
  untouched until portable backup and verified restore are complete.

## Verification snapshot — 2026-08-03 (roadmap Slice 3)

- 70 unit/integration tests and 19 UI tests passed serially on the iOS 26.5
  simulator. Coverage includes fixed service/credit intent semantics, unresolved
  duration prompts, exact dependency identity, active/foreground/startup store
  refresh, typed reminder routing, cold routing, and warm-draft reset.
- Unsigned Debug and Release device builds and Xcode Analyze passed. Extracted
  App Intents metadata contains exactly three promoted commands and compiled
  English, Russian, and Ukrainian shortcut phrases.
- A Sol Max adversarial re-review returned GO with no P0 or P1 findings. The
  accepted P2 residual is that App Intents exposes no durable invocation ID for
  correlating a hypothetical new system retry after a committed save; heuristic
  deduplication would incorrectly suppress legitimate repeated entries.
- The signed smoke build is isolated as `com.kikuai.hourleaf.slice3smoke` with
  the visible name `Hourleaf Shortcut Smoke`. Its first installation attempt
  stopped before installing because Xcode had no signed-in Personal Team
  account; no app or data on the physical iPhone was changed. Device lifecycle,
  Action Button, and reminder-tap acceptance remain an owner-controlled gate.
