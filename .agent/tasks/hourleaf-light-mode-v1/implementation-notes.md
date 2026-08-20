# Implementation notes

- The existing UI already uses semantic grouped backgrounds, primary and
  secondary foreground styles, and the `AccentColor` asset. The implementation
  should therefore add preference control at the app root rather than fork the
  visual design into separate palettes.
- Appearance is intentionally device-local and independent of ledger backup.
- The winning implementation rung is native SwiftUI: `@AppStorage` persists a
  raw enum value and `preferredColorScheme` applies the resolved optional color
  scheme at the app root. No service, repository API, migration, or dependency
  was added.
- The Settings control is a native menu picker rather than three permanently
  wide segments, so Russian and Ukrainian copy remains readable at narrow and
  large-text widths.
- Unknown stored values fall back to Follow iPhone. This makes future enum
  changes and damaged local preferences safe without affecting ledger data.
- XCUITest exposes native menu selection through the selected menu item rather
  than the picker's `value`; the UI test verifies that selected state and the
  persisted state after process relaunch.
