# Implementation notes

- The final scope follows the owner's physical-device decision: keep one light
  confirmation after an hour or minute wheel settles, keep feedback for a
  successful Bible-study count change, and remove per-numeral scrolling
  feedback.
- `TimeWheelPicker` remains SwiftUI's native wheel. The temporary
  `UIPickerView`/scroll-observation experiment and all diagnostic hooks were
  removed after it failed to improve the physical result and regressed width.
- The wheel uses the existing Picker-facing binding to distinguish a committed
  manual value from parent-driven updates. Initial rendering, identical values,
  and the post-save form reset remain quiet.
- A small Core Haptics helper provides the exact lightweight transient that was
  perceptible on the owner's unplugged iPhone, with a UIKit light-impact
  fallback. It adds no permission, dependency, analytics, or backend.
- The Bible-study `+` and `−` controls prepare feedback before the repository
  operation and play it only after a successful count change. Rejected and
  disabled actions stay quiet.
- One enabled-by-default local `@AppStorage` preference controls both behaviors.
  It does not touch Core Data, backups, reports, synchronization, or Watch data.
- The Settings label and short explanation are localized in English, Russian,
  and Ukrainian. The native Toggle supplies its standard accessible state.
- The Add screen keeps `.scrollBounceBehavior(.basedOnSize)`: it stays fixed
  when content fits and still scrolls for compact screens, large text, banners,
  and the keyboard. Each wheel owns its half-row hit area; unit labels do not
  intercept touches.
- Device verification used only the isolated `Hourleaf Haptic Test` bundle
  (`com.kikuai.hourleaf.hapticpreview`) and its separate database UUID. The
  App Store Hourleaf bundle and ledger were never uninstalled or modified.
