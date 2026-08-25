# App Review notes for Hourleaf 1.0

This file is the maintained source for the App Review Information Notes field.
Update it when the review path, shipped capabilities, or verified physical-device
matrix changes. Keep private reviewer contact details only in App Store Connect.

## Version 1.0.3 update

Build 14 fixes voice entry through Siri and Apple Shortcuts on iPhone and Apple
Watch. The “Record service” and “Record credit” shortcuts now ask for a duration
when needed and save the entry without opening Hourleaf. This update adds no
account, purchase, external service, sensitive-data permission, or new data
category. The existing physical-device recording still demonstrates the
unchanged core entry, history, report, sharing, and data-management flows.

## Paste-ready Notes field

```text
Hourleaf 1.0 review information (Guideline 2.1)

1. PHYSICAL-DEVICE RECORDING
The attached file “Hourleaf-App-Review-iPhone-15-Pro-iOS-26.6.mov” was captured from build 11 on a physical iPhone 15 Pro running iOS 26.6. It begins with launch and shows service entry, the monthly Bible-study count, list/calendar history, service-year progress, monthly report preparation, the system share sheet, and local data tools. It contains no private user data.

2. TESTED DEVICES
- iPhone 15 Pro — iOS 26.6 — build 11: launch, service/credit entry, Bible-study count, history, calendar, report preparation/share sheet, settings, backup/export access, and relaunch.
- Apple Watch Series 10 — watchOS 26.6 — embedded companion launch and direct service/credit entry to the paired iPhone.
Hourleaf is an iPhone app with an optional Apple Watch companion; iPad is not a supported target.

3. FUNCTIONS, AUDIENCE, AND VALUE
Hourleaf is a private, local-first ministry-time ledger for individual volunteers who keep their own records. Users record service or credit time, optionally add a note, review/edit/delete entries in list or calendar form, track service-year progress, store a monthly Bible-study count, prepare a monthly text report, and share it using the iOS share sheet. It also provides local reminders, backup/restore, CSV, optional Shortcuts/widgets, and Apple Watch entry. It replaces handwritten or spreadsheet calculations while keeping service and credit separate.

4. ACCESS AND SETUP
No account, login, purchase, credentials, or sample file is required. In Add, choose Service or Credit, select hours/minutes, optionally add a note, then Save. Use the Bible studies stepper for the current month. History switches between list/calendar. Progress shows totals and the report; review it, prepare it, then tap Share. Settings > Data Management provides local backup, restore, CSV export/import; import/restore opens Apple’s document picker only after its action is tapped. Notifications are requested only if a reviewer enables a reminder. On a paired Watch, choose Service or Credit, set hours/minutes with the Digital Crown, and confirm; the paired iPhone commits the entry.

5. EXTERNAL SERVICES OR PLATFORMS
Hourleaf has no backend, account system, authentication provider, payment processor, ads, analytics, tracking, AI service, external data provider, or third-party SDK. It uses Apple on-device frameworks only: Core Data, App Intents/Shortcuts, WidgetKit/Control Center, WatchConnectivity, UserNotifications, the share sheet, and document picker. Records remain on-device unless explicitly exported or shared.

6. REGIONAL DIFFERENCES
The same features and content are available in every region. There are no geographic restrictions or region-specific services. The interface and report month names are localized in English, Russian, and Ukrainian.

7. REGULATED INDUSTRY / PROTECTED MATERIAL
Hourleaf provides no regulated service and contains no protected third-party database, media, or organization-owned content. Users enter only their own records. It is an independent personal tool, not affiliated with or endorsed by any religious organization; no authorization or professional credential is required.

PRIVACY AND PERMISSIONS
There is no user-generated public content or reporting/blocking system. Hourleaf requests no location, contacts, camera, microphone, photos, health, tracking, or other sensitive-data permission. Local notification permission is requested only after the user enables a reminder.
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
