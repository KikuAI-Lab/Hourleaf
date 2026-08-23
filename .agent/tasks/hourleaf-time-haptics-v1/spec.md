# Hourleaf time-selection haptics

Canonical owner: `KikuAI-Lab/Hourleaf#7`.

Artifact class: temporary task artifact. Finalize it as cold proof after every
acceptance criterion passes; implementation truth remains in code and tests.

## Original request

Add a light vibration to the hour and minute counters for a more satisfying
response, and let the user disable it in Settings.

## Physical-device correction — 2026-08-23/24

The owner tested the signed build on an iPhone 15 Pro and could not feel either
SwiftUI `.sensoryFeedback(.selection)` or `.impact(weight: .light, intensity: 1)`
while spinning the wheels. The task was reopened because an API request alone
was not acceptance; the enabled interaction needed a restrained but clearly
perceptible physical tap on the owner's device.

Physical diagnosis later established that the earlier "no feedback" reports
were made while the iPhone was charging, which suppressed the felt response in
the owner's setup. Once unplugged, Core Haptics was perceptible after the wheel
settled and on the Bible-study counter. After testing the per-numeral experiment,
the owner explicitly removed it from scope. The accepted behavior is one light
confirmation after a time wheel commits its value, plus the same confirmation
when the Bible-study counter changes successfully.

## Acceptance criteria

- **AC1 — Settled-time feedback:** A manual change made through either the
  iPhone hour wheel or minute wheel produces one restrained, perceptible
  confirmation after the wheel commits its selected value when feedback is
  enabled. Per-numeral feedback during scrolling is explicitly out of scope.
- **AC2 — User control:** A single ordinary-language Settings toggle controls
  this feedback. It is enabled by default and persists locally between app
  launches.
- **AC3 — No false feedback:** Initial rendering, external binding updates,
  and the programmatic form reset after saving do not request feedback.
- **AC4 — Localized and accessible:** The toggle and its concise explanation
  are available in English, Russian, and Ukrainian and expose an understandable
  accessibility label/value through the native Toggle control.
- **AC5 — Minimal architecture:** The implementation uses Apple frameworks
  already available on iOS 17, adds no permission, dependency, analytics, or
  backend, and does not change Watch behavior.
- **AC6 — Verification:** Focused policy/settings tests, relevant UI tests, the
  complete unit suite, the stable app-owned UI suite, Release build, release
  guard, localization validation, and `git diff --check` pass.
- **AC7 — Wheel interaction area:** The visual design stays native while the
  wheel owns the surrounding half-row hit area, including the noninteractive
  unit-label overlay.
- **AC8 — No unnecessary page drag:** The Add screen does not rubber-band when
  its content fits, while retaining scrolling when content truly exceeds the
  viewport for small screens, accessibility sizes, banners, or the keyboard.
- **AC9 — Bible-study counter feedback:** A successful increase or decrease of
  the monthly Bible-study counter produces one light selection tick when the
  same feedback setting is enabled. Rejected, disabled, or failed updates do
  not request feedback.

## Constraints

- Do not change the App Store version/build, archive, upload, submit, withdraw,
  or replace a Store build as part of this source correction.
- Preserve the local ledger and all existing defaults.
- Keep Settings calm: one toggle and one short consequence-focused sentence.
- Physical verification must use the separate signed `Hourleaf Haptic Test` bundle
  (`com.kikuai.hourleaf.hapticpreview`). Never overwrite, uninstall, or mutate
  the App Store Hourleaf bundle or its ledger. Apple Watch remains out of scope.

## Non-goals

- Apple Watch crown haptics.
- Success, error, notification, navigation, save-button, or unrelated button
  haptics.
- Custom vibration patterns or intensity controls.
- A new onboarding step, animation, telemetry event, or release submission.

## Assumptions

- “Counter” refers to the manual hour and minute wheel pickers on the iPhone
  Add screen.
- The preference belongs in local UserDefaults/AppStorage alongside existing
  lightweight presentation preferences, not in the ministry ledger or backup.
- Use the physically proven lightweight Core Haptics transient at the committed
  wheel selection; custom wheel wrappers, scroll introspection, stronger
  patterns, and success feedback remain out of scope.

## Verification plan

1. Unit-test the default-on preference value, localized copy, and the
   user-vs-programmatic feedback trigger policy as pure Swift.
2. UI-test Settings discoverability and persistence plus the successful
   Bible-study count/report flow without claiming that Simulator proves feel.
3. Run the relevant focused tests, then the complete stable CI-equivalent unit
   and app-owned UI suites on the one canonical iPhone simulator.
4. Run unsigned Release build, release guard, localization/key checks, and
   `git diff --check`.
5. Install only the isolated Haptic Test bundle on the connected iPhone 15 Pro and
   confirm settled-time feedback, Bible-study counter feedback, wheel area, and
   page stability using the owner's accepted physical observations.
6. Record exact commands and results in the task evidence bundle.
