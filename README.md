# Hourleaf

Hourleaf is a private, local-first iPhone ledger for recording ministry and
credit time, following service-year progress, and preparing monthly reports.

- App Store name: **Hourleaf: Ministry Hours**
- Platform: iOS 17+
- Languages: English, Russian, Ukrainian
- Storage: local Core Data on this iPhone
- Privacy: no accounts, ads, tracking, or third-party analytics

## Development

Open `Hourleaf.xcodeproj` in Xcode 26 or run:

```sh
xcodebuild -project Hourleaf.xcodeproj \
  -scheme Hourleaf \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

Every current build is local-only. Hourleaf does not sync records or require an
account; portable backups leave the app only when the user chooses to share
them. Private iCloud sync is a separate future opt-in feature.

## Personal Team device testing

An Apple Developer Program membership is not required for local testing on a
connected iPhone. The installer builds a temporary project copy with a separate
local bundle identifier and the `HOURLEAF_LOCAL_DEVICE` compilation condition.
The production target is not modified:

```sh
./scripts/install-local-device.sh <PERSONAL_TEAM_ID> <DEVICE_ID>
```

When the standard local Hourleaf app is already installed, close it first. The
installer refuses to continue while Hourleaf is running, copies every readable
file from its data container to a private recovery directory under Application
Support, and verifies the exact file inventory, sizes, and SHA-256 manifest
before it builds or installs the update.

For the isolated Slice 3 shortcut smoke build, append `--slice3-smoke`. It
uses `com.kikuai.hourleaf.slice3smoke`, separate from both production and the
normal local-device bundle, and is visibly named **Hourleaf Shortcut Smoke**
on the device so its disposable data cannot be mistaken for the real app:

```sh
./scripts/install-local-device.sh <PERSONAL_TEAM_ID> <DEVICE_ID> --slice3-smoke
```

All variants keep data locally on the iPhone. TestFlight still requires an
active Apple Developer Program membership. Personal Team provisioning is
temporary, so the app must be rebuilt periodically. Its data lives in a
separate app sandbox and will not automatically move into the future App Store
build.

To move data to a later TestFlight or App Store build:

1. In the old local build, create and save a backup.
2. Install and open the new Hourleaf build.
3. In Data Management, choose that backup and restore it.
4. Check entries, reports, reminders, and settings in the new app.
5. Remove the old local build only after those checks, if you wish.
