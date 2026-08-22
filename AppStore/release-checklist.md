# Hourleaf 1.0.2 submission checklist

## Source and package

- [x] Release guard and self-test pass.
- [x] Full unit suite passes: 504 of 504 tests.
- [x] Full UI suite passes 52 of 52 tests, including Light appearance, compact Add layout,
      Settings guides, accessibility text, and the existing ledger flows.
- [x] Signed release archive contains the iPhone app, Watch app, WidgetKit
      extension, app icons, all three localizations, and the required privacy
      manifests.
- [x] Signed distribution entitlements match the production App Group and
      bundle identifiers.
- [ ] Migration from the Personal Team build is verified using an exported
      Hourleaf backup before the old app is removed.

## App Store Connect

- [x] Active Apple Developer Program membership.
- [ ] Create version `1.0.2` on the existing iOS app record with bundle ID
      `com.kikuai.hourleaf`. The release candidate is build `13`.
- [x] Copy metadata from `AppStore/metadata` and URLs from `AppStore/README.md`.
- [ ] Enter private App Review contact details.
- [ ] Complete App Privacy using `AppStore/privacy-details.md`.
- [x] Complete the age-rating questionnaire using `AppStore/age-rating.md`.
- [ ] Add only the verified accessibility features from
      `AppStore/accessibility.md`.
- [x] Confirm export compliance: only exempt Apple operating-system encryption;
      `ITSAppUsesNonExemptEncryption` is `NO` in each shipping bundle.
- [x] Prepare reviewed iPhone and Apple Watch screenshots with no personal
      data. Upload remains an owner action in App Store Connect.
- [ ] Choose availability, trader status, and manual or automatic release.
- [ ] Upload the signed archive and wait for processing before submission.
      For a command-line owner upload, use
      `AppStore/ExportOptions-AppStore.plist`; never add account credentials to
      that file or the repository.

## Physical acceptance

- [ ] Fresh install and update both preserve the ledger.
- [ ] Add, edit, delete, monthly report, backup, restore, CSV, reminders, and
      relaunch persistence pass on iPhone.
- [ ] Apple Watch service and credit entry pass on a paired physical Watch.
- [ ] Siri/Shortcuts claims are included in marketing only after the exact
      public-distribution phrases pass on iPhone and Watch.
