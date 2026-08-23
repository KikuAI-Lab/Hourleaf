# Hourleaf time-selection haptics

Canonical owner: `KikuAI-Lab/Hourleaf#7`.

Artifact class: temporary task artifact. Finalize it as cold proof after every
acceptance criterion passes; implementation truth remains in code and tests.

## Original request

Add a light vibration to the hour and minute counters for a more satisfying
response, and let the user disable it in Settings.

## Acceptance criteria

- **AC1 — Native light feedback:** A manual change made through either the
  iPhone hour wheel or minute wheel requests one subtle native selection
  feedback event when feedback is enabled.
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

## Constraints

- Hourleaf 1.0.2 (13) is already Waiting for Review and must not be replaced,
  withdrawn, rebuilt, bumped, or uploaded as part of this task.
- Preserve the local ledger and all existing defaults.
- Keep Settings calm: one toggle and one short consequence-focused sentence.
- Do not install on, mirror, or control a physical iPhone or Apple Watch.

## Non-goals

- Apple Watch crown haptics.
- Success, error, notification, navigation, or button haptics.
- Custom vibration patterns or intensity controls.
- A new onboarding step, animation, telemetry event, or release submission.

## Assumptions

- “Counter” refers to the manual hour and minute wheel pickers on the iPhone
  Add screen.
- The preference belongs in local UserDefaults/AppStorage alongside existing
  lightweight presentation preferences, not in the ministry ledger or backup.
- Native selection feedback is the appropriate strength; stronger impact or
  success feedback would conflict with Hourleaf's calm interaction style.

## Verification plan

1. Unit-test the default-on preference value and the user-vs-programmatic
   feedback trigger policy as pure Swift.
2. UI-test Settings discoverability, default-on state, off/on changes, and
   relaunch persistence without claiming that Simulator proves vibration.
3. Run the relevant focused tests, then the complete stable CI-equivalent unit
   and app-owned UI suites on the one canonical iPhone simulator.
4. Run unsigned Release build, release guard, localization/key checks, and
   `git diff --check`.
5. Record exact commands and results in the task evidence bundle; a physical
   feel check remains optional owner acceptance for a later signed build.
