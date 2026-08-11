# App Review notes for Hourleaf 1.0

Hourleaf is a local-first personal time ledger. No account or sign-in is
required. The app contains no purchases, advertising, analytics, or remote
service dependency.

## Main review path

1. Launch Hourleaf and complete the local onboarding values.
2. On the Add tab, choose Service or Credit, select a duration, and save.
3. Open History to review, edit, or delete the entry, and switch between list
   and calendar presentation.
4. Open Progress to inspect monthly totals and prepare a report.
5. Open Settings > Data Management to inspect local backup, restore, CSV
   export, and CSV import. The system document picker is shown only after an
   explicit action.

## Apple Watch

The embedded Hourleaf Watch app is a companion to the iPhone app. Open it on a
paired Watch, choose Service or Credit, select hours and minutes with the
Digital Crown, and confirm. The entry is committed by the paired iPhone and
then appears in iPhone History. If the iPhone is unreachable, the Watch app
shows a localized failure and does not claim that the entry was saved.

## Permissions

- Notifications are requested only when the user enables a reminder.
- App Group access is used only by the app and its WidgetKit extension for
  minimal totals/timer state.
- No location, contacts, camera, microphone, photos, health, or tracking
  permission is requested.

App Review contact details must be entered privately in App Store Connect.
