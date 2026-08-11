# Hourleaf 1.0 submission checklist

## Source and package

- [x] Release guard and self-test pass.
- [x] Full unit suite passes. The full UI suite passed 48 of 49 tests; the only
      failure was a stale expected localization string, and its corrected
      focused rerun passed.
- [x] Unsigned release archive contains the iPhone app, Watch app, WidgetKit
      extension, app icons, all three localizations, and the required privacy
      manifests.
- [ ] Signed distribution entitlements match the production App Group and
      bundle identifiers.
- [ ] Migration from the Personal Team build is verified using an exported
      Hourleaf backup before the old app is removed.

## App Store Connect

- [ ] Active Apple Developer Program membership.
- [ ] Create the iOS app record with bundle ID `com.kikuai.hourleaf`, version
      `1.0.0`, build `1`, and name `Hourleaf: Ministry Hours`.
- [ ] Copy metadata from `AppStore/metadata` and URLs from `AppStore/README.md`.
- [ ] Enter private App Review contact details.
- [ ] Complete App Privacy using `AppStore/privacy-details.md`.
- [ ] Complete the age-rating questionnaire using `AppStore/age-rating.md`.
- [ ] Add only the verified accessibility features from
      `AppStore/accessibility.md`.
- [ ] Confirm export compliance: only exempt Apple operating-system encryption;
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
