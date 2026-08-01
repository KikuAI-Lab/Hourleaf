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
