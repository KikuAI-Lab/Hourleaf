# Evidence

## Final verdict

All acceptance criteria have current PASS evidence. The fresh read-only
adversarial verifier reported no actionable findings; see `verdict.json`.

## AC1 — PASS

- `AppAppearance.system` is the `@AppStorage` default.
- `AppAppearanceTests.testAppearanceMapsToPreferredColorScheme` proves the
  default resolves to `nil`, which delegates appearance to iOS.
- Unknown stored values also resolve to `.system`.

## AC2 — PASS

- Settings contains one native menu picker with the three frozen choices.
- `AppAppearanceTests.testAppearanceCopyExistsInEverySupportedLanguage` passed.
- Full localization key comparison passed with 376 identical keys in each of
  EN/RU/UK; each locale has five appearance keys.

## AC3 — PASS

- `HourleafApp` applies the preference above the launch-state switch using
  `preferredColorScheme`.
- `testLightAppearanceChoicePersistsAndKeepsCriticalSurfacesUsable` selected
  Light, terminated the app, relaunched it, and confirmed Light remained the
  selected option before continuing. Result: 1/1 PASS.

## AC4 — PASS

- The same UI test completed Quick Entry, saved-confirmation toast, History,
  Progress, report review, Settings, and Data Management in Light: 1/1 PASS.
- Visual receipt `raw/light-quick-entry-ready.png` confirms semantic grouped
  backgrounds, readable text/controls, and the blue accent in Light.
- Accent asset was not changed and remains `#4A6DA7`.

## AC5 — PASS

- The final diff adds appearance code only to the iPhone app root and iPhone
  Settings. No Watch, widget, shared-state, or project target file changed.
- The no-sign test build validated the embedded Watch app and Quick Surfaces
  extension.

## AC6 — PASS

- Full `HourleafTests`: 504/504 PASS (`raw/full-unit-summary.json`).
- Light appearance UI flow: 1/1 PASS (`raw/ui3-summary.json`).
- Dark/settings/Russian/Ukrainian UI regression batch: 4/4 PASS
  (`raw/ui-regressions-summary.json`).
- `build-for-testing` with signing disabled passed for all targets
  (`raw/verification-receipt.txt`).
- Release-readiness guard and its self-test passed; `git diff --check`, plist
  lint, and localization parity passed (`raw/verification-receipt.txt`,
  `raw/localization-parity.log`).
