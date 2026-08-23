# Evidence

## Final verdict

All acceptance criteria have current PASS evidence. The fresh read-only cold
review found no actionable correctness, privacy, accessibility, or scope
issues; see `verdict.json`.

## AC1 — PASS

- The Add screen's hour and minute wheel bindings request SwiftUI's native
  `sensoryFeedback(.selection)` only after a changed manual selection.
- Focused feedback-policy tests passed 3/3.
- The native platform primitive adds no custom pattern, permission, SDK, or
  dependency.

## AC2 — PASS

- A single native Settings toggle, enabled by default, stores its value in
  local `UserDefaults` through `@AppStorage`.
- The focused UI flow proved default-on, disable, navigation retention,
  relaunch persistence, re-enable, and a second relaunch: 1/1 PASS.

## AC3 — PASS

- Feedback is triggered only in the Picker-facing binding setter. Parent
  updates, including the post-save reset, write the source state directly and
  bypass it; same-value reconciliation is ignored.
- The pure policy test covers disabled, unchanged, and external-update cases.

## AC4 — PASS

- Settings uses an accessible native Toggle with a concise label, hint, and
  footer.
- EN/RU/UK plist lint and complete key parity passed with 378 keys per locale.
- Focused tests verify the exact localized title and explanation in all three
  supported languages.

## AC5 — PASS

- Only Quick Entry opts into feedback; the shared picker defaults to off, so
  history editing, timer review, and Apple Watch behavior are unchanged.
- The final diff changes no Watch source, project, entitlement, privacy,
  storage-schema, or version file.
- The Release build validated the iPhone app, Quick Surfaces extension, and
  embedded Watch app, all still reading 1.0.2 (13).

## AC6 — PASS

- Focused unit tests: 3/3 PASS.
- Focused Settings UI test: 1/1 PASS.
- Clean stable suite: 563/563 PASS, comprising 510 unit/integration tests and
  53 app-owned UI tests.
- Unsigned generic-simulator Release build: PASS for all three targets.
- Release guard, guard self-test, `git diff --check`, localization lint, and
  localization parity: PASS.

## Test-maintenance correction

The first full run exposed an unrelated iOS 26.5 test assumption: the system
Share Sheet close button followed the simulator language and was labelled in
Russian while Hourleaf launched in English. The two sharing tests now select
Apple's `header.closeButton` accessibility identifier. Both targeted tests and
the final full suite pass; application sharing behavior was not changed.

## Residual acceptance boundary

Simulator testing cannot prove the subjective physical strength of the Taptic
Engine response. A feel check can be done in a later signed next-version build;
this task intentionally did not access a physical iPhone or Watch and did not
change or upload the already-submitted 1.0.2 (13) build.
