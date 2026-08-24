# Evidence

## Final verdict

UNKNOWN. The card-name/discovery repair is verified, and the newly observed
execution failure has a bounded authentication-policy fix with green source,
compiled-metadata, Release, and regression evidence. The production Store build
still has the former policy. A disposable physical build must reach the
duration prompt before the source fix can be called device-proven.

## AC1 — PASS: discoverable metadata

- A fresh unsigned Release build completed without App Intents metadata or
  localization errors for the iPhone and Watch targets.
- Compiled service action titles are `Record service`, `Запиши служение`, and
  `Запиши служіння`; the corresponding credit titles remain localized.
- Built-in App Shortcut phrases retain Apple's required application-name token.

## AC2 — PASS: honest invocation contract

- The app-name-free phrase is implemented as a user-created Shortcut whose card
  has that exact name. The public EN/RU/UK guide now says this explicitly.
- Public support no longer promises that an iPhone-created Shortcut will run on
  Apple Watch. Watch users are directed to the native Hourleaf watch app.

## AC3 — PASS: executable action contract

- Service and credit remain separate intents, each using one spoken duration
  and the existing validated command/repository path.
- The service card retains fixed kind `Служение`; credit remains a distinct
  fixed-kind action. No persistence or schema code changed.
- Focused iPhone App Intent plus Watch contract tests passed 26/26; the complete
  Hourleaf unit/integration suite passed 511/511.
- Compiled Release metadata declares background execution and authentication
  policy `0` for the two iPhone and two Watch recording actions.

## AC4 — UNKNOWN: fixed binary on a physical device

- Read-only device inspection confirmed Hourleaf 1.0.2 (13) on an iPhone 15 Pro
  with iOS 26.6 and an Apple Watch Series 10 with watchOS 26.6.
- The physical iPhone visibly contains enabled cards named exactly
  `Запиши служение` and `Запиши кредит`. The service action was refreshed from
  the currently installed Hourleaf action gallery.
- The owner then invoked the direct Siri path and reported `Что-то пошло не
  так`; the currently installed 1.0.2 (13) binary therefore fails this
  acceptance criterion.
- Mirrored execution of the same production action returned the more specific
  iOS message `Это действие не разрешено` before duration collection. Shortcut
  privacy readback showed Hourleaf access and locked execution already enabled.
- The replacement policy is compiled and automatically verified, but is not in
  the installed Store build. A disposable physical build remains the decisive
  no-save check.
- No duration was supplied and no ledger entry was written. A direct spoken
  invocation remains the only missing physical result.

## AC5 — PASS: regression safety

- Generic iOS Release build: PASS.
- Release-readiness guard and its self-test: PASS.
- EN/RU/UK plist lint and App Intents metadata processing: PASS.
- kikuai.dev focused Hourleaf pages: 4/4 PASS; complete site gate: 279/279 PASS;
  production Nuxt build: PASS with 296 prerendered routes.
- No dependency, data model, entitlement, privacy manifest, account, analytics,
  bundle identifier, Store build, app container, or ledger changed.

## Root causes and forward fixes

1. Discovery: the service card was named `Записать время`, while the promoted
   phrase was `Запиши служение`. The card and localized action title now match.
2. Execution: the recording intents explicitly required authentication even
   though the Shortcuts flow is intended to work hands-free and while locked.
   The four iPhone/Watch service and credit actions now use `.alwaysAllowed`
   without exposing any ledger content or changing the validated write path.
