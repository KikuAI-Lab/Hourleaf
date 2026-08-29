# Hourleaf delivery checklist

## Active release: 1.0.4 (17)

This active section is the maintained release contract. It is superseded when
the next version becomes the source candidate; dated receipts below remain
immutable history.

### Source and package

- [x] All iPhone, WidgetKit, and Watch shipping configurations use version
      `1.0.4` build `17`.
- [x] Release guard and self-test pass.
- [x] Full unit suite passes: 523 of 523 tests on the canonical iPhone 17 /
      iOS 26.5 simulator; 53 of 53 app-owned UI tests also pass.
- [x] Unsigned Release build contains the iPhone app, small/medium WidgetKit
      extension, and embedded Watch app.
- [x] Signed App Store archive is created and inspected after owner
      authorization.

### Physical acceptance

- [x] Install build `17` without losing the existing iPhone ledger.
- [x] Add the small and medium Hourleaf widgets on iPhone using the build 15
      TestFlight baseline.
- [ ] With the same Apple Account and a nearby iPhone, add the medium widget on
      Mac. The small Continuity widget is already verified.
- [x] Verify Russian copy, opt-in totals,
      privacy redaction, refresh after an entry, and the quick-entry deep link.
- [x] Verify that build `17` asks “Сколько минут?” and that service and credit
      voice actions each create exactly one requested entry.
- [x] Compare fresh device crash logs after both actions and confirm no new
      Hourleaf `0xdead10cc` termination.
- [x] Resolve diagnostic cleanup: on 2026-08-29 the owner explicitly chose to
      keep the build `16` diagnostic entries and build `17` canaries. No cleanup
      deletion or direct database mutation was performed.

### Owner-controlled distribution

- [x] Create the signed archive and inspect production entitlements.
- [x] Upload build `17` to App Store Connect after explicit owner approval.
- [x] Wait for App Store Connect processing and verify the build is ready for
      internal testing.
- [x] Attach build `17` to version `1.0.4`, save EN/RU/UK release notes, and
      submit after explicit owner approval.

### Build 17 App Review submission receipt — 2026-08-29

- App Store Connect version `1.0.4` was created on the existing Hourleaf iOS
  record and processed build `17` was attached. The iPhone and Apple Watch
  screenshot sets were retained.
- EN/RU/UK promotional text, release notes, and search keywords were saved.
  The English subtitle was updated to `Private log for iPhone & Watch` for the
  next version; the app name remains `Hourleaf: Ministry Hours` in every
  localization.
- Current build-17 App Review information was saved. The existing private
  reviewer contact details remained only in App Store Connect.
- Automatic release after approval remains selected. The overview rating was
  not reset.
- At 18:40 EEST on 2026-08-29, App Store Connect confirmed one submitted item.
  A fresh readback showed `iOS 1.0.4`, build `17`, with status
  `Waiting for Review`; the review draft count returned to zero.
- Submission metadata source commit:
  `2c51f10221db2b785c6f308fd8b171fccb5aeafa`. Approval and public storefront
  availability are separate future gates and are not claimed by this receipt.

### Build 17 local candidate receipt — 2026-08-28

- Build `16` persisted both requested Siri entries correctly, but physical
  crash logs showed two separate `RUNNINGBOARD` `0xdead10cc` terminations after
  the actions. Matching dSYM symbolication placed both in the shared
  quick-surface file lock during host-app reconciliation.
- Build `17` adds a balanced UIKit background assertion around only that short
  host-app reconciliation. It does not change the ledger writer, Core Data
  model, App Intent phrases, WidgetKit extension, or Watch app behavior.
- Focused verification passed 38 of 38 tests. The complete source candidate
  passed 523 of 523 unit/integration tests and 53 of 53 app-owned UI tests.
- Release guard, guard mutation self-test, and unsigned Release package
  inspection passed for build `17`.
- Source commit `8453356ba01ab0442bc5bd4706610b7619728eb4` passed GitHub
  Actions run `33161907471`. The retained archive is
  `~/Library/Developer/Xcode/Archives/2026-08-28/Hourleaf 1.0.4 (17).xcarchive`.
  Inspection confirmed matching `1.0.4 (17)` versions for the iPhone app,
  WidgetKit extension, and Watch app; valid signatures; privacy manifests;
  App Intents metadata; three dSYMs; and production entitlements matching the
  inspected build `16` baseline.
- Xcode completed the App Store Connect upload at 17:58 EEST on 2026-08-28.
  The completion sheet identified `Hourleaf 1.0.4 (17)` as uploaded, Organizer
  read back build `17` as `Uploaded to Apple`, and the distribution critical log
  was empty. At 18:03 EEST App Store Connect listed build `17` as ready for
  testing and assigned to the `Hourleaf Internal` group.
- TestFlight updated the physical iPhone 15 Pro on iOS 26.6 from build `16` to
  build `17` in place. Read-only table comparison showed that every existing
  ledger row was unchanged. The Russian Siri flows asked “Сколько минут?” and
  persisted exactly one requested service entry and one requested credit entry.
  Fresh system crash logs contained no new Hourleaf crash file after either
  action. On 2026-08-29 the owner explicitly chose to retain the diagnostic and
  canary entries; no cleanup mutation was performed.

### Build 16 TestFlight receipt — 2026-08-28

- Source candidate: `079bed9b2a6bcf0c6d4a46418cc543b19aaeb43a`;
  evidence commit: `26684c2b8b9701131e06c8421f95d9aa6c65f9ec`;
  GitHub CI run `32987802797` passed the release guard and mutation self-test,
  517 unit/integration tests, and 53 UI tests.
- Retained archive:
  `~/Library/Developer/Xcode/Archives/2026-08-27/Hourleaf 1.0.4 (16).xcarchive`.
  Inspection confirmed matching `1.0.4 (16)` versions for the iPhone app,
  WidgetKit extension, and Watch app; production bundle IDs and App Group;
  valid signatures, privacy manifests, App Intents metadata, and dSYMs.
- Xcode completed the App Store Connect upload at 19:21 EEST on 2026-08-27.
  Xcode Organizer read back build `16` as uploaded to Apple, and TestFlight on
  the physical iPhone offered `1.0.4 (16)` for installation, proving processing
  completed and the build was ready for internal testing.
- TestFlight replaced the public `1.0.3 (14)` app in place on the physical
  iPhone 15 Pro running iOS 26.6. `devicectl` read back the installed app as
  `1.0.4 (16)`, and the paired Apple Watch Series 10 as
  `com.kikuai.hourleaf.watchkitapp` `1.0.4 (16)`.
- The App Store container is not downloadable through the developer container
  service, so this update does not claim the table-by-table SQLite comparison
  available for build 15. A private before/after UI comparison confirmed the
  same current-month service total, credit total, and Bible-study count, with
  no onboarding or reset after first launch or a subsequent relaunch.
- This is an archive, upload, processing, and internal-install receipt only.
  Build `16` has not been attached to an App Store version or submitted for
  review. Its exact Siri prompt and both production voice actions remain the
  final physical release smoke.

### Prior build 15 TestFlight baseline — 2026-08-26

- Source commit: `0c496e5868157fcd0093fb0805af858cb1889f09` on
  `main`; GitHub CI run `32945038505` passed 514 unit/integration tests and
  53 UI tests.
- Retained archive:
  `~/Library/Developer/Xcode/Archives/2026-08-26/Hourleaf 1.0.4 (15).xcarchive`.
- The archive contains production bundle IDs `com.kikuai.hourleaf`,
  `com.kikuai.hourleaf.quick-surfaces`, and
  `com.kikuai.hourleaf.watchkitapp`, all at version `1.0.4` build `15`, with
  matching localizations, privacy manifests, valid signatures, and dSYMs.
- Xcode completed the App Store upload successfully. App Store Connect showed
  processing as completed and build `15` as ready for testing in the
  `Hourleaf Internal` group.
- Before updating, a private local device-container backup and a consolidated
  SQLite snapshot passed integrity checks. TestFlight then updated the existing
  production bundle in place on the iPhone 15 Pro running iOS 26.6. The
  separate local-development bundle remained installed and unchanged.
- Post-update integrity and table-by-table comparison preserved every ledger,
  settings, reminder, archive, receipt, preset, and revision row. The only
  database change was the expected report-state revision timestamp written
  when the updated app launched; the report's semantic state was unchanged.
- This is an upload and internal-install receipt only. The widgets still need
  physical iPhone/Mac gallery, privacy, refresh, localization, and deep-link
  acceptance before build `15` is attached to a new App Store version.

## Historical release: 1.0.3 (14)

### Source and package

- [x] Release guard and self-test pass.
- [x] Full unit suite passes: 512 of 512 tests on isolated GitHub runners.
- [x] Full app-owned UI suite passes 53 of 53 tests, including voice-entry
      setup, Light appearance, compact Add layout, accessibility text, and the
      existing ledger flows.
- [x] Manual Store capture lane passes 1 of 1 with 12 EN/RU/UK attachments on
      the canonical iPhone 17 / iOS 26.5 simulator.
- [x] The final standard `main` CI run passes with the portable report and
      backup fixtures enabled.
- [x] Signed release archive contains the iPhone app, Watch app, WidgetKit
      extension, app icons, all three localizations, and the required privacy
      manifests.
- [x] Signed distribution entitlements match the production App Group and
      bundle identifiers.
- [ ] Migration from the Personal Team build is verified using an exported
      Hourleaf backup before the old app is removed.

### App Store Connect

- [x] Active Apple Developer Program membership.
- [x] Create version `1.0.3` on the existing iOS app record with bundle ID
      `com.kikuai.hourleaf`. The release candidate is build `14`.
- [x] Retain the existing localized metadata and URLs, and save the EN/RU/UK
      version-specific release notes for `1.0.3`.
- [x] Keep the existing private App Review contact details in App Store
      Connect. The provider accepted them without exposing them to Git or chat.
- [x] Complete App Privacy using `AppStore/privacy-details.md`; the existing
      answers passed the version-submission validation.
- [x] Complete the age-rating questionnaire using `AppStore/age-rating.md`.
- [ ] Add only the verified accessibility features from
      `AppStore/accessibility.md` after the documented physical-device smoke.
      No new accessibility claim was added in this Mac-only pass.
- [x] Confirm export compliance: only exempt Apple operating-system encryption;
      `ITSAppUsesNonExemptEncryption` is `NO` in each shipping bundle.
- [x] Retain the reviewed iPhone and Apple Watch screenshots with no personal
      data from the existing App Store version.
- [x] Availability and trader status are configured; 175 territories are
      selected and automatic release is enabled.
- [x] Upload the signed archive and wait for processing before submission.
      For a command-line owner upload, use
      `AppStore/ExportOptions-AppStore.plist`; never add account credentials to
      that file or the repository.
- [x] Attach build `14`, save EN/RU/UK release notes, and submit iOS version
      `1.0.3` after the owner's explicit submission authorization.

### Physical acceptance (not performed in this Mac-only submission pass)

- [ ] Fresh install and update both preserve the ledger.
- [ ] Add, edit, delete, monthly report, backup, restore, CSV, reminders, and
      relaunch persistence pass on iPhone.
- [ ] Apple Watch service and credit entry pass on a paired physical Watch.
- [ ] Siri/Shortcuts claims are included in marketing only after the exact
      public-distribution phrases pass on iPhone and Watch.

### Upload receipt — 2026-08-25

- Source commit: `4e0ec83cfa08481a89bc1ced73c4dbc651f3deb2` on `main`.
- GitHub CI run `32856152121` passed: release guard, self-test, 512 unit and
  integration tests, and 53 UI tests.
- Retained archive:
  `~/Library/Developer/Xcode/Archives/2026-08-25/Hourleaf 1.0.3 (14).xcarchive`.
- The archive contains production bundle IDs `com.kikuai.hourleaf`,
  `com.kikuai.hourleaf.quick-surfaces`, and
  `com.kikuai.hourleaf.watchkitapp`, all at version `1.0.3` build `14`.
- Xcode recorded a successful App Store upload with no errors or warnings.
  App Store Connect then completed processing and showed build `14` as
  `Ready to Submit` in version group `1.0.3`.
- At the end of this upload-only pass, no App Store version draft or App Review
  submission had yet been created. The later submission receipt below
  supersedes that temporary state.

### App Review submission receipt — 2026-08-25

- App Store Connect version `1.0.3` was created and linked to processed build
  `14`.
- Localized release notes were saved in English, Russian, and Ukrainian; the
  existing iPhone and Apple Watch screenshots and localized metadata were
  retained.
- The App Review notes were updated for build `14`, including the current voice
  entry path, privacy posture, regional consistency, and physical-device test
  matrix. Private reviewer contact details remain only in App Store Connect.
- Submission `fadebc9c-324d-46bc-8eb6-5d00748432d5` was sent at 17:52 EEST.
  App Store Connect confirmed one submitted item: iOS app `1.0.3 (14)`, status
  `Waiting for Review` (`Ожидание проверки`).
- Automatic release after approval and immediate rollout to all users remain
  selected. At submission time, `1.0.2` was still the public version; this
  receipt does not claim approval or storefront availability for `1.0.3`.
