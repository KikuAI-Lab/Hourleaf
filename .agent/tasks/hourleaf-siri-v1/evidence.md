# Evidence

## Current regression verdict

PASS. The source repair, compiled Siri metadata, build 16 package, synced
Shortcut routing, independent CI, and production-device persistence are all
proven. Two owner-confirmed voice invocations produced exactly two distinct
one-minute service entries, so no duplicate write was observed.

## AC1 — PASS: discoverable metadata

- A fresh unsigned build 16 Release build completed with no App Intents or
  localization error for iPhone, Watch, or WidgetKit.
- RU/UK/EN SSU training completed for fixed service and credit actions.
- Compiled metadata exposes `RecordServiceTimeIntent` and
  `RecordCreditTimeIntent`, while the retained legacy `RecordTimeIntent` is
  explicitly non-discoverable.

## AC2 — PASS: honest invocation contract

- Built-in App Shortcut phrases retain Apple's application-name token.
- The short app-name-free phrases remain user-created Shortcut names; the
  routing receipt proves which production actions those names invoke.

## AC3 — PASS: executable action contract

- The fixed service intent delegates to the existing validated persistence
  path with `.service`; credit remains its own fixed action.
- Focused App Intent tests passed 22/22. The complete Hourleaf suite passed
  517/517.

## AC4 — PASS: device diagnosis without ledger replacement

- Read-only inspection confirmed both production and isolated development
  Hourleaf bundles remain installed.
- The production ledger was copied only for private before/after verification;
  it was not migrated, replaced, or deleted.
- No private totals or notes are stored in this public task bundle.

## AC5 — PASS: regression safety

- Release guard and its mutation self-test pass.
- EN/RU/UK app and Watch string files pass plist lint.
- Build 16 contains the iPhone app, Watch app, and WidgetKit extension at the
  same version/build number.
- No dependency, schema, entitlement, account, analytics, or SDK was added.

## AC6 — PASS: explicit minute prompt

- App and Watch localizations now ask `How many minutes?`, `Сколько минут?`, or
  `Скільки хвилин?` and label the parameter as minutes.
- Tests parse all six localization files and enforce the prompt contract.

## AC7 — PASS: fixed service identity

- The promoted service App Shortcut uses `RecordServiceTimeIntent`.
- Compiled metadata confirms that the fixed service action is discoverable and
  always allowed, while the legacy generic action remains executable but is
  hidden from new setup.

## AC8 — PASS: unambiguous synced route

- Before repair, `Запиши служение` targeted the isolated development bundle,
  while the production action used a different name.
- After a non-destructive Shortcuts rename, `Запиши служение` targets
  `com.kikuai.hourleaf.RecordTimeIntent`, `Запиши кредит` targets
  `com.kikuai.hourleaf.RecordCreditTimeIntent`, and the preserved development
  card is named `Старое тестовое служение`.

## AC9 — PASS: final production voice write

- The owner invoked `Запиши служение` twice and confirmed that the second run
  was intentional.
- A fresh read-only production-container comparison found exactly two new
  active service entries of one minute and exactly two matching immutable
  `create` revisions, all with source `shortcut` and 19 seconds apart.
- The observed two writes therefore match two invocations exactly; Siri did not
  create a duplicate entry. Credit remains on its separate fixed production
  action and was already reported working by the owner.
- Installing build 16 to physically confirm its more explicit prompt remains a
  release acceptance gate, not an unresolved persistence defect.

## Supporting artifacts

- `raw/regression-automated-receipt.txt`
- `raw/regression-device-routing-receipt.txt`
- `raw/regression-physical-siri-receipt.txt`
- `raw/focused-tests-summary.json`
- `raw/full-unit-summary.json`
