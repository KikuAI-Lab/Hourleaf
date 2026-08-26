# App Privacy answers for Hourleaf 1.0

Use these answers for the App Privacy questionnaire in App Store Connect.

- Does this app collect data? **No**
- Data used to track the user: **None**
- Data linked to the user: **None**
- Data not linked to the user: **None**

Hourleaf has no developer account, advertising SDK, analytics SDK, or remote
backend. Ministry entries, notes, preferences, reports, backups, and imports are
processed locally. A user can explicitly share report text or export a backup
or CSV through the system share sheet; this user-directed transfer is not data
collected by KikuAI.

Notifications are local. Apple Watch sends an entry to the paired iPhone using
Apple's Watch Connectivity framework. The WidgetKit extension reads a minimal
App Group sidecar containing the optional monthly totals, Bible-study count,
service-year progress, and timer state; it never reads notes or history.
