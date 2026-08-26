# Hourleaf Siri reliability audit and repair

## Original task

The owner reports that the Siri voice commands configured for Hourleaf are not
understood. Recheck the complete iPhone and Apple Watch path and repair the
smallest proven defect.

## Regression report — 2026-08-26

The owner reports that the current production build asks an ambiguous duration
question. The credit shortcut saves a spoken bare number as minutes, but the
service shortcut replies as if it succeeded without adding a visible service
entry. The connected iPhone currently contains both the production and the
older isolated development Hourleaf bundles, while synced Shortcuts contain
both `Запиши служение` and `Запиши служение App Store`. Treat a success reply
without a durable entry as a critical failure and re-open this task.

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
- **AC6 — Explicit unit prompt:** iPhone and Watch service/credit actions ask
  specifically for minutes in RU, UK, and EN. A bare spoken number continues to
  be interpreted as whole minutes.
- **AC7 — Fixed service identity:** The promoted iPhone service shortcut uses a
  distinct fixed-service App Intent, symmetric with the existing fixed-credit
  intent. The legacy generic intent remains executable for existing shortcuts
  but is no longer the promoted service action.
- **AC8 — Unambiguous device route:** The canonical user Shortcut named
  `Запиши служение` resolves to the production Hourleaf action rather than the
  isolated development bundle. Any old duplicate is preserved under a clearly
  non-spoken name or removed only after its target is proven and its isolated
  container is privately backed up.
- **AC9 — Honest physical result:** On the production ledger, one controlled
  service invocation adds exactly one service entry with the spoken minute
  count. Credit still adds exactly one credit entry. Siri/Shortcuts must not
  return the success dialog before the repository write completes.

## Constraints

- Preserve all Hourleaf data and do not uninstall the production app.
- Do not publish an App Store build as part of this task.
- Use official Apple documentation or the installed SDK as the source of truth
  for Siri/App Shortcuts behavior.
- Keep user-facing instructions plain and short.
- Do not delete or replace either app container before a private device backup
  and exact bundle/Shortcut routing readback.

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
6. Inspect the synced custom Shortcut actions and remove the production/local
   naming collision without touching the production ledger.
7. Run one controlled production service write and compare the durable ledger
   before/after; repeat for credit only if needed to prove symmetry.
