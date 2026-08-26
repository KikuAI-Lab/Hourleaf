# Evidence

## Current regression verdict

UNKNOWN. The source repair, compiled Siri metadata, build 16 package, and
synced Shortcut routing are proven. One final production-device voice
invocation is still required for AC9; no completion claim is made before that
durable before/after readback.

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

## AC9 — UNKNOWN: final production voice write

- No owner voice invocation has yet been confirmed after the synced route was
  repaired, and build 16 has not been installed.
- Required proof: one spoken service invocation creates exactly one production
  service entry with source `shortcut`; credit remains symmetric; build 16 asks
  explicitly for minutes before saving.

## Supporting artifacts

- `raw/regression-automated-receipt.txt`
- `raw/regression-device-routing-receipt.txt`
- `raw/regression-physical-siri-receipt.txt`
- `raw/focused-tests-summary.json`
- `raw/full-unit-summary.json`
