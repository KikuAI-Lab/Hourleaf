# Hourleaf

Hourleaf is a private, local-first iPhone ledger for recording ministry and
credit time, following service-year progress, and preparing monthly reports.

- App Store name: **Hourleaf: Ministry Hours**
- Platform: iOS 17+
- Languages: English, Russian, Ukrainian
- Storage: Core Data with private iCloud/CloudKit mirroring
- Privacy: no accounts, ads, tracking, or third-party analytics

## Development

Open `Hourleaf.xcodeproj` in Xcode 26 or run:

```sh
xcodebuild -project Hourleaf.xcodeproj \
  -scheme Hourleaf \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

CloudKit is intentionally disabled in simulator and UI-test stores. A signed
device build uses the private `iCloud.com.kikuai.hourleaf` container.

## Personal Team device testing

An Apple Developer Program membership is not required for local testing on a
connected iPhone. The installer builds a temporary project copy with a separate
local bundle identifier, no CloudKit entitlements, and the
`HOURLEAF_LOCAL_DEVICE` compilation condition. The production target is not
modified:

```sh
./scripts/install-local-device.sh <PERSONAL_TEAM_ID> <DEVICE_ID>
```

This variant keeps all data locally on the iPhone. CloudKit mirroring and
TestFlight still require an active Apple Developer Program membership. Personal
Team provisioning is temporary, so the app must be rebuilt periodically. Its
data lives in a separate app sandbox and will not automatically move into the
future App Store build.
