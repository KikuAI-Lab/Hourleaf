# Hourleaf implementation notes

Class: temporary task artifact. The canonical task surface is
KikuAI-Lab/Hourleaf#3. Delete or reduce this file to durable follow-ups when the
MVP is accepted.

## Decisions

- Native SwiftUI, Core Data, and UserNotifications are used without third-party
  dependencies.
- Reporting totals and service-year progress are separate calculations. A
  carried minute can affect a report but never changes the date on which the
  underlying service occurred.
- Service and credit time use the same reporting policy but maintain separate
  carry balances. Credit time never contributes to the 600-hour goal.
- Every current build is local-only. A future private-iCloud adapter remains
  behind the repository boundary and requires explicit opt-in plus migration
  gates; it is not part of the current runtime.
- Opening balances let a person adopt Hourleaf mid-year without manufacturing
  historical daily entries. The 600-hour goal never caps the saved opening
  progress; opening hours use direct non-negative numeric input.
- Reporting remainders never cross the service-year boundary from August into
  September. The legacy Core Data flag remains only for store compatibility and
  is ignored by domain calculations.
- Personal Team testing uses a separate `com.kikuai.hourleaf.local` bundle ID.
  The installer does not claim or alter the future App Store bundle ID. Records
  created under this local bundle ID will not migrate automatically to the
  future App Store sandbox.
- Settings use plain-language examples for reporting rules, clearly identify
  editable report wording, and explain the local-only privacy boundary without
  exposing a storage choice. Developer links replace internal App Store metadata.
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
- Portable backup v1 is a canonical, password-free `.hourleafbackup` JSON file.
  It preserves the exact raw values of all ten V2 entities, uses SHA-256 for
  corruption detection, never overwrites an existing destination, and is
  protected before its first byte is written. A portable backup is readable by
  anyone who obtains the file, so the future UI must warn plainly when notes are
  included.

## Delivery gates

- Apple Developer signing, App ID and iCloud container registration, CloudKit
  production-schema promotion, App Store Connect creation, and 2FA require the
  repository owner's Apple account.
- Opening or closing a share sheet is not proof of delivery. The report stays
  prepared, no automatic confirmation appears, and it is recorded as sent only
  after the user taps the persistent Mark as sent action.
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

## Verification snapshot — 2026-08-03 (roadmap Slice 4)

- The accepted backup format covers all 10 V2 entities and all 115 model
  attributes, including explicit `nil` values, Unicode notes, soft-deleted
  entries, mutation histories, report snapshots, reminders, presets, archives,
  settings, and legacy compatibility values.
- Strict canonical JSON, SHA-256, bounded input and record counts, graph
  validation, exact raw Core Data mapping, and atomic no-overwrite publication
  are covered by 26 focused backup tests. The stable golden fixture remains
  3,387 bytes with checksum
  `23be45de3687f2200b02f3c87dc42722ab67d10ece3e9d74e3c591631cc66533`.
- After a minimality pass removed only dead and redundant comparisons, the
  backup branch passed 100/100 tests serially. Rebasing it over the accepted
  Shortcuts slice produced a final 115/115 combined pass. Unsigned Debug and
  Release device builds and Xcode Analyze also passed; the Core Data model,
  project, entitlements, privacy manifest, and dependency surface remain
  unchanged.
- A Sol Max adversarial review returned GO with no P0 or P1 findings. Signed
  device file-protection readback and File Provider behavior remain Slice 5
  gates. Restore must validate a disposable store, create a verified
  pre-restore backup, replace the whole local store, and prove an exact digest
  after relaunch before any real iPhone ledger can be touched.

## Verification snapshot — 2026-08-03 (Report Readiness v1)

- The final tree passed 243 unit/integration tests and 30 UI tests on the iPhone
  17 simulator with iOS 26.5. Coverage includes zero-entry completed months,
  atomic review/prepare/send transitions, immutable corrections, service-only
  year archives, separate credit and carry calculations, deterministic Undo,
  current-month draft previews, EN/RU/UK copy, and Accessibility XXXL.
- Unsigned generic-device Release build and Xcode Analyze passed. The three
  Localizable.strings catalogs contain the same 266 keys, the shortcut catalog
  remains valid in English, Russian, and Ukrainian, and exactly three system
  shortcuts are promoted.
- Core Data model V1 remains
  `dbfcef97f98cc80657a8eb9c453ecf925371d1a8bccb18177c1cb33dbfe72606`;
  V2 remains
  `69d8472b17c6322444621824dbece6e77882ed15e472dba0f5a04ac89b335c45`.
  No protected model, entitlement, privacy manifest, or dependency changed.
- One bounded adversarial pass found one P2: a legacy current-month snapshot
  could override its live draft preview. The preview selector now always uses
  the live draft in the collecting month; a focused regression and the full
  test matrices pass afterward. No P0 or P1 finding remained.
- This slice was not installed on or read from the physical iPhone. Signed
  device work remains gated on a verified portable backup, disposable restore
  canary, and explicit owner permission.

## Verification snapshot — 2026-08-08 (Quick Surfaces + Timer M2)

- The host-only M2 implementation adds redacted projection reconciliation, a
  default-off timer, explicit review before saving, stable idempotent
  finalization, restore interlocks, compact settings and quick-entry UI, and
  post-write refresh for App Intents. It does not add an extension target, App
  Group entitlement, or ledger access outside the host app.
- 379 unit/integration tests and 41 UI tests passed on the iPhone 17 simulator
  with iOS 26.5. The six timer acceptance flows cover default-off behavior,
  relaunch persistence, review without notes, save plus Undo, confirmed
  discard, and preservation of an existing manual draft.
- Generic-simulator Release build and Xcode Analyze passed. The three
  localization catalogs contain the same 343 keys, exactly three App Shortcuts
  remain promoted, the Xcode project and both Core Data schemas are unchanged,
  and the Release binary contains no simulator UI-test injection strings.
- One bounded adversarial pass found no P0 or P1 issue. Its invalid-wall-clock
  privacy edge is fixed: an existing shown projection can still be physically
  redacted using its last validated timestamp, while new or shown projections
  continue to fail closed without a valid clock.
- Signed-device, App Group, widget, and Control Center work remains M3-gated.
  Before a future extension can write timer state, restore also needs an atomic
  cross-process lease; the current host-only double-read interlock is sufficient
  only while no extension exists.
