# Hourleaf Siri reliability audit and repair

## Original task

The owner reports that the Siri voice commands configured for Hourleaf are not
understood. Recheck the complete iPhone and Apple Watch path and repair the
smallest proven defect.

## Acceptance criteria

- **AC1 — Discoverable metadata:** A fresh iPhone and Watch build emits valid
  App Intents metadata with localized RU/UK/EN service and credit shortcuts and
  no metadata-processor errors.
- **AC2 — Honest invocation contract:** The exact phrases users can say are
  supported by Apple's App Shortcuts contract. In-app/public guidance must not
  promise an app-name-free Siri phrase unless it is backed by a user-created
  Shortcut with that exact name.
- **AC3 — Executable action:** Service and credit intents each accept one spoken
  duration, use the shared validated command path, and retain the correct fixed
  entry kind. Focused automated tests pass.
- **AC4 — Device diagnosis:** Current physical iPhone/Watch availability and
  installed Hourleaf state are read back without deleting or replacing the
  owner's ledger. A real Siri result is recorded as PASS or honestly UNKNOWN if
  the remaining step requires the owner's voice/unlock.
- **AC5 — Regression safety:** Localization parity, Release build, focused
  tests, and repository hygiene pass. No new SDK, account, analytics, or data
  migration is introduced.

## Constraints

- Preserve all Hourleaf data and do not uninstall the production app.
- Do not publish an App Store build as part of this task.
- Use official Apple documentation or the installed SDK as the source of truth
  for Siri/App Shortcuts behavior.
- Keep user-facing instructions plain and short.

## Non-goals

- Redesigning the manual iPhone or Watch entry UI.
- Adding speech recognition, a server, AI, or a custom voice pipeline.
- App Store upload or release.

## Assumptions

- The reported symptom is recognition/discovery until evidence proves an
  execution or authorization failure.
- App-name-free invocation may require a user-created Shortcut; built-in App
  Shortcut phrases may have stricter grammar.

## Verification plan

1. Inspect current source, localized phrase catalogs, Xcode project settings,
   and compiled App Intents metadata for iPhone and Watch.
2. Run focused App Intent and Watch contract tests.
3. Compare phrase behavior with the installed SDK and current official Apple
   documentation.
4. Inspect connected physical-device/app state read-only and run a bounded
   signed smoke only if it will not destroy data.
5. Record per-criterion evidence, then perform a fresh verifier pass.
