# Evidence

## Final verdict

UNKNOWN. The source, localized metadata, current iPhone Shortcut cards, release
build, automated tests, and public guidance are repaired and verified. The one
remaining acceptance gate is a direct owner-voice Siri invocation on the
unlocked physical iPhone; iPhone Mirroring cannot prove that authenticated
path.

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
- Focused App Intent tests passed 18/18; the complete Hourleaf unit/integration
  suite passed 511/511.

## AC4 — UNKNOWN: direct Siri invocation

- Read-only device inspection confirmed Hourleaf 1.0.2 (13) on an iPhone 15 Pro
  with iOS 26.6 and an Apple Watch Series 10 with watchOS 26.6.
- The physical iPhone visibly contains enabled cards named exactly
  `Запиши служение` and `Запиши кредит`. The service action was refreshed from
  the currently installed Hourleaf action gallery.
- Mirrored execution returned the iOS message `Это действие не разрешено` while
  the mirrored session controlled an otherwise locked handset. That result is
  not evidence about direct Siri execution on an unlocked device.
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

## Root cause and forward fix

The existing service Shortcut card was named `Записать время`, while the phrase
shown to the owner was `Запиши служение`. Siri invokes a user-created Shortcut
by its card name. The physical card is now renamed, and the localized service
action title is aligned with that promoted name so future setup does not create
the same mismatch.
