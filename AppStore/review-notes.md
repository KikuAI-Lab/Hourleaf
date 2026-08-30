# App Review notes for Hourleaf

This file is the maintained source for the App Review Information Notes field.
Update it when the review path, shipped capabilities, or verified physical-device
matrix changes. Keep private reviewer contact details only in App Store Connect.

## Version 1.0.5 candidate update

Build 19 adds a read-only monthly-report action for Apple Shortcuts, localized
Share Hourleaf and Rate Hourleaf actions in Settings, and correct Ukrainian
guide routing. It also gives the empty note fields explicit localized VoiceOver
labels on physical devices. The report action returns only the existing calculated report
text, requires local device authentication, compares the ledger before and
after reading, never changes an entry, and never sends anything. Hourleaf may
ask for an App Store rating only after the user successfully marks a report as
sent; the native StoreKit request waits two seconds, is cancelled if the user
leaves the screen, and is attempted at most once per app version. This update
adds no account, purchase, backend, third-party SDK, sensitive-data permission,
or new data category.

Physical-device acceptance and the final build-19 test matrix are still
pending. Keep the paste-ready 1.0.4 notes below unchanged until those checks
pass and build 19 is actually selected for submission.

## Version 1.0.4 update

Build 17 adds small and medium Hourleaf widgets and makes Siri entry
unambiguous. With monthly totals enabled in Hourleaf settings, the small widget
shows service, credit, and Bible-study count; the medium widget also shows
service-year progress. Siri asks specifically how many minutes to record, and
service and credit use separate actions. Totals remain opt-in and
privacy-sensitive. This update adds no purchase, external service,
sensitive-data permission, or new data category.

## Previous 1.0.3 update

Build 14 fixes voice entry through Siri and Apple Shortcuts on iPhone and Apple
Watch. The “Record service” and “Record credit” shortcuts now ask for a duration
when needed and save the entry without opening Hourleaf. This update adds no
account, purchase, external service, sensitive-data permission, or new data
category. The existing physical-device recording still demonstrates the
unchanged core entry, history, report, sharing, and data-management flows.

## Paste-ready Notes field

```text
Hourleaf 1.0.4 (build 17) review information

UPDATE SCOPE
Build 17 adds small and medium Hourleaf widgets and makes Siri entry unambiguous. With monthly totals enabled in Hourleaf settings, the small widget shows service, credit, and Bible-study count; the medium widget also shows service-year progress. Siri asks specifically how many minutes to record, and service and credit use separate actions. Totals remain opt-in and privacy-sensitive. This update adds no account, purchase, external service, sensitive-data permission, or new data category.

ACCESS AND MAIN FEATURES
No account, login, purchase, credentials, or sample file is required. Launch Hourleaf and use Add to choose Service or Credit, set hours/minutes, optionally add a note, and save. The Bible studies stepper records the current month's count. History switches between list and calendar. Progress prepares the monthly report and opens the system share sheet. Settings > Data Management provides local backup, restore, and CSV export/import. Settings > Widgets & Control Center lets the user opt in to showing monthly totals outside Hourleaf. Add an Hourleaf small or medium widget from the iPhone widget gallery. On a paired Apple Watch, choose Service or Credit, set time with the Digital Crown, and confirm; the paired iPhone commits the entry.

VOICE ENTRY
In Apple Shortcuts, run “Record service” or “Record credit”. Each action asks “How many minutes?” (localized in English, Russian, and Ukrainian) and saves through the same validated local entry path as the app. Service and credit have separate fixed actions; the retained legacy service action remains executable only for existing user shortcuts and is not offered for new setup. The actions work offline and do not reveal history, notes, totals, or reports.

AUDIENCE AND VALUE
Hourleaf is a private, local-first ministry-time ledger for individual volunteers keeping their own records. It replaces handwritten or spreadsheet calculations while keeping service and credit separate.

EXTERNAL SERVICES AND PRIVACY
Hourleaf has no backend, account provider, payment processor, ads, analytics, tracking, AI service, external data provider, or third-party SDK. It uses Apple on-device frameworks only. Records stay on-device unless the user explicitly exports or shares them. The WidgetKit extension reads only a minimal App Group sidecar with opt-in aggregate totals and never reads notes or history. Notification permission is requested only after the user enables a reminder. No location, contacts, camera, microphone, photos, health, or tracking permission is requested.

REGIONS AND THIRD-PARTY MATERIAL
Features are consistent across all regions and localized in English, Russian, and Ukrainian. Hourleaf is not a regulated service and contains no protected third-party database, media, or organization-owned content. It is an independent personal tool and is not affiliated with or endorsed by any religious organization.

TEST EVIDENCE
Core flows were tested on an iPhone 15 Pro running iOS 26.6 and an Apple Watch Series 10 running watchOS 26.6. The unchanged core entry, history, report, sharing, and data-management flows remain demonstrated by the physical-device recording supplied during the version 1.0 review. Build 17 passed 523 unit and integration tests and 53 app-owned UI tests. On the physical iPhone, the Russian Siri service and credit actions each asked how many minutes to record and each saved exactly one requested entry. Fresh system crash logs after both actions contained no new Hourleaf crash or running-board suspension termination.
```

## Resolution Center reply

```text
Hello App Review,

Thank you for the clarification. We have added all requested information to the App Review Information Notes field and attached a physical-device recording named “Hourleaf-App-Review-iPhone-15-Pro-iOS-26.6.mov”. The recording was captured from build 11 on a physical iPhone 15 Pro running iOS 26.6 and demonstrates the core user flow from launch through entry, Bible-study count, history/calendar, report preparation, the iOS share sheet, and local data-management access.

Hourleaf requires no account, credentials, purchase, subscription, or external service. The app is local-first, functions consistently in all regions, and is not part of a regulated industry or based on protected third-party material. The submitted build remains unchanged.

Please let us know if any additional path would be helpful.
```

## Recording acceptance

- Capture the submitted production app, version `1.0.0` build `11`, on the
  physical iPhone 15 Pro running iOS 26.6.
- Launch with the disposable in-memory review fixture so no private ledger data
  is recorded and the real on-device store is never changed.
- Begin the video before the app launches and show the app icon or launch event.
- Show Add, the Bible-study counter, History list/calendar, Progress/report,
  the system share sheet, and Settings > Data Management.
- Do not send a report, import a file, restore a backup, enable notifications,
  expose personal notes, or show device/account identifiers.
- Verify the encoded video visually, confirm the file has an audio-free H.264
  video track, and retain it outside Git unless Apple requests a new recording.

## Recording receipt — 2026-08-18

- File: `Hourleaf-App-Review-iPhone-15-Pro-iOS-26.6.mov`
- Source: physical iPhone 15 Pro running iOS 26.6, submitted build 11
- Duration: `105.5054` seconds
- Encoded media: one H.264 High video track, `604x1332`, `yuv420p`; no
  audio track
- Size: `3,775,458` bytes
- SHA-256: `a4719d123cfc420edb9e92f459eed1b18cd572329c2bd9822532c58d76b19ffe`
- Visual acceptance: launch, service save, monthly Bible-study count,
  list/calendar history, progress, report review, system share sheet, Settings,
  Backup and export, and Privacy are visible; no private ledger data, account
  identifier, notification prompt, or black tail is present.
- The recording remains outside Git and must be uploaded only as the private
  App Review attachment.
