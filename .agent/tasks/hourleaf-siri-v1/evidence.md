# Evidence

## Final verdict

PASS. Discovery, cold background execution, iPhone Siri, and Apple Watch Siri
are all proven on separately signed development bundles without replacing the
production app or touching its ledger. A controlled iPhone invocation and a
controlled Watch invocation each produced exactly one durable service entry.

## AC1 — PASS: discoverable metadata

- A fresh unsigned Release build completed without App Intents metadata or
  localization errors for the iPhone and Watch targets.
- Compiled service action titles are `Record service`, `Запиши служение`, and
  `Запиши служіння`; the corresponding credit titles remain localized.
- Built-in App Shortcut phrases retain Apple's required application-name token.

## AC2 — PASS: honest invocation contract

- The app-name-free phrase is implemented as a user-created Shortcut whose card
  has that exact name. The public EN/RU/UK guide says this explicitly.
- The guide remains conservative about Apple Watch until the repaired Store
  build ships. Physical evidence now additionally proves the synced custom
  Shortcut can run from Apple Watch against the repaired iPhone intent.

## AC3 — PASS: executable action contract

- Service and credit remain separate intents, each using one spoken duration
  and the existing validated command/repository path.
- The service card retains fixed kind `Служение`; credit remains a distinct
  fixed-kind action. No persistence or schema code changed.
- Focused iPhone App Intent plus Watch contract tests passed 27/27; the complete
  Hourleaf unit/integration suite passed 512/512.
- Compiled Release metadata declares background execution and authentication
  policy `0` for the two iPhone and two Watch recording actions.
- A regression test proves `HourleafApp.init()` registers the live App Intent
  dependencies before any SwiftUI body evaluation.

## AC4 — PASS: fixed binary on physical iPhone and Apple Watch

- Read-only device inspection confirmed Hourleaf 1.0.2 (13) on an iPhone 15 Pro
  with iOS 26.6 and an Apple Watch Series 10 with watchOS 26.6.
- The repaired app was installed under isolated local bundle identifiers on
  both devices. The production iPhone and Watch bundles remained present and
  untouched.
- Before eager dependency registration, the isolated binary still returned
  `Это действие не разрешено` despite authentication policy `0`. This ruled out
  policy alone and isolated the cold dependency boundary.
- After the fix, one exact iPhone Siri invocation returned `Готово` and added
  exactly one 1-minute `shortcut` entry to the isolated ledger.
- One exact Apple Watch Siri invocation returned `Хорошо` and added exactly one
  further 1-minute `shortcut` entry to the same isolated ledger.
- The Watch result's `shortcut` source proves the synced custom Shortcut ran the
  repaired iPhone intent. It is distinct from the native Watch app's direct
  WatchConnectivity writer.
- The production ledger was never read, migrated, mutated, or deleted.

## AC5 — PASS: regression safety

- Generic iOS Release build: PASS.
- Release-readiness guard and its self-test: PASS.
- EN/RU/UK plist lint and App Intents metadata processing: PASS.
- kikuai.dev focused Hourleaf pages: 4/4 PASS; complete site gate: 279/279 PASS;
  production Nuxt build: PASS with 296 prerendered routes.
- No dependency, data model, entitlement, privacy manifest, account, analytics,
  production bundle identifier, Store build, or production app container
  changed.
- CI timeout was raised from 45 to 60 minutes because the previous run completed
  all 53 UI tests with zero failures and was cancelled only while `xcodebuild`
  was finishing at the job boundary.

## Root causes and forward fixes

1. Discovery: the service card was named `Записать время`, while the promoted
   phrase was `Запиши служение`. The card and localized action title now match.
2. Locked-use contract: the recording intents explicitly required
   authentication even though they only write validated time and reveal no
   ledger data. The four iPhone/Watch service and credit actions now use
   `.alwaysAllowed` while preserving the same validation and write path.
3. Cold execution: App Intent dependencies were registered while lazily
   constructing an inline `StateObject`. Background App Intent launch can run
   before that construction. `HourleafApp.init()` now eagerly creates the
   launcher and registers the exact repository/router dependencies before the
   SwiftUI scene body is needed.
