# Hourleaf 1.0.3 delivery checklist

## Source and package

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

## App Store Connect

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

## Physical acceptance (not performed in this Mac-only submission pass)

- [ ] Fresh install and update both preserve the ledger.
- [ ] Add, edit, delete, monthly report, backup, restore, CSV, reminders, and
      relaunch persistence pass on iPhone.
- [ ] Apple Watch service and credit entry pass on a paired physical Watch.
- [ ] Siri/Shortcuts claims are included in marketing only after the exact
      public-distribution phrases pass on iPhone and Watch.

## Upload receipt — 2026-08-25

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

## App Review submission receipt — 2026-08-25

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
