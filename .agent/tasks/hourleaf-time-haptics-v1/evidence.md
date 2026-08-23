# Evidence

## Final verdict

PASS. Hourleaf uses the owner's accepted restrained behavior: one light
confirmation when an Add-screen time wheel commits after settling, plus one
confirmation after a successful Bible-study count change. Per-numeral scrolling
feedback and its experimental picker wrapper are absent.

## AC1 — PASS: settled-time confirmation

- `TimeWheelPicker` remains SwiftUI's native wheel and requests feedback only
  from its Picker-facing binding after a changed manual value is committed.
- The Core Haptics transient is the same platform path the owner felt on the
  unplugged iPhone before the later per-numeral experiment. The owner explicitly
  asked to restore this behavior and drop feedback for every passing numeral.
- Focused policy tests passed 3/3; the relevant Add/edit UI flows passed 4/4.

## AC2 — PASS: user control

- One native Settings toggle controls time and Bible-study feedback. It defaults
  to enabled and persists locally through `@AppStorage`.
- The complete UI suite includes the disable, navigation, relaunch, re-enable,
  and second-relaunch persistence flow.

## AC3 — PASS: no false feedback

- Initial rendering, identical values, parent-driven binding changes, and the
  post-save reset bypass the Picker-facing setter or fail the pure trigger
  policy, so they remain quiet.

## AC4 — PASS: localization and accessibility

- The native Toggle has a plain-language title, hint, visible footer, and native
  accessibility state.
- EN/RU/UK plist lint and complete key parity passed with 378 keys per locale.
- Focused tests verify the exact copy in all three supported languages.

## AC5 — PASS: minimal platform implementation

- The implementation uses Core Haptics with a UIKit light-impact fallback and
  adds no dependency, permission, analytics, backend, entitlement, or schema.
- History editing, timer review, and Apple Watch do not opt into the feedback.

## AC6 — PASS: verification

- Focused tests: 3 unit + 4 relevant UI = 7/7 PASS.
- Complete unit/integration suite: 510/510 PASS.
- Complete stable app-owned UI suite: 53/53 PASS.
- Total stable suite: 563/563 PASS.
- Unsigned generic-simulator Release build: PASS for Hourleaf,
  HourleafQuickSurfaces, and HourleafWatch; bundle readback remains 1.0.2 (13).
- Release guard, guard self-test, localization lint/parity, experimental-code
  absence check, and `git diff --check`: PASS.

## AC7 — PASS: wheel interaction area and width

- Each native wheel owns one half of the time row, clips within that half, and
  exposes the surrounding rectangle as its interaction area. Unit labels do not
  intercept touches.
- The fresh iPhone simulator screenshot was visually inspected: both wheels fit
  evenly within the card, without the experimental horizontal spread.

## AC8 — PASS: stable Add page

- `.scrollBounceBehavior(.basedOnSize)` keeps the page fixed when its content
  fits while preserving real scrolling for compact screens, accessibility text,
  banners, and the keyboard.
- The default-size UI check proves that the Bible-study controls are visible
  without an initial scroll.

## AC9 — PASS: Bible-study confirmation

- The `+` and `−` controls prepare feedback before the repository request and
  play it only after `updateBibleStudyCount` succeeds while the preference is
  enabled.
- The owner previously confirmed this Core Haptics path on the unplugged iPhone;
  the focused UI test proves the count reaches the current-month report.

## Device and data boundary

- Physical verification used only the separately signed `Hourleaf Haptic Test`
  app (`com.kikuai.hourleaf.hapticpreview`) with isolated database UUID
  `B5EE266B-DA58-44DF-891A-65C8D713D450` on the owner's iPhone 15 Pro.
- The App Store Hourleaf bundle and ledger were not uninstalled, overwritten,
  migrated, or modified. No Store build was archived, uploaded, or submitted.
