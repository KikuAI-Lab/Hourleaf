# Implementation notes

## 2026-08-26 regression decision receipt

- lazy-senior lower rung: native App Intents plus one tiny fixed-service action
  delegating the already tested persistence path.
- GitHub prior art: skipped because this is a repo-local identity/routing bug.
- New code is justified because a stored Shortcut must reference a fixed action
  identity; an `AppShortcut` constructor's preconfigured enum value is not that
  identity.

## 2026-08-26 regression findings and repair

- The synced Shortcut database proved the reported asymmetry was a routing
  collision, not a silent Core Data failure. `Запиши кредит` targeted
  `com.kikuai.hourleaf.RecordCreditTimeIntent`, while the canonical
  `Запиши служение` still targeted
  `com.kikuai.hourleaf.local.RecordTimeIntent`. The production service card was
  separately named `Запиши служение App Store`.
- The old local card was preserved and renamed `Старое тестовое служение`.
  The production card was renamed `Запиши служение`. A fresh local database
  readback confirmed the canonical service and credit names now both reference
  `com.kikuai.hourleaf`.
- The production source now promotes a distinct `RecordServiceTimeIntent`,
  matching the fixed identity already used by credit and both Watch actions.
  The generic `RecordTimeIntent` remains compiled with the same identifier for
  existing cards, but is no longer discoverable when users add a new action.
- iPhone and Watch prompts now explicitly say `How many minutes?`,
  `Сколько минут?`, or `Скільки хвилин?`. The parameter remains a native
  duration measured in minutes, so compound spoken durations are still valid
  and a bare number keeps its existing minute interpretation.
- The Store candidate was advanced from build 15 to build 16 because build 15
  already exists in App Store Connect. All six iPhone, WidgetKit, and Watch
  shipping configurations now share version `1.0.4` build `16`.
- App Intent focused tests passed 22/22 and the full unit/integration suite
  passed 517/517. The build 16 unsigned generic Release build passed Store
  validation, generated RU/UK/EN Siri training assets, and embedded both the
  Watch app and WidgetKit extension.
- Distribution remains owner-gated. No build 16 archive, upload, TestFlight
  install, App Store attachment, or submission has been performed.

- The shipped iPhone action was titled `Записать время`, while the public guide
  instructed the owner to invoke a custom Shortcut named `Запиши служение`.
  Siri runs a user-created Shortcut by its exact card name, so the mismatch was
  sufficient to make the documented app-name-free phrase undiscoverable.
- The first repair aligned the service action title with the promoted Shortcut
  title in EN/RU/UK. The action identifier, parameters, persistence path, Core
  Data model, and bundle identifiers remained unchanged.
- A regression test parses all three app localizations and requires
  `intent.record.title` to equal `intent.shortcut.add_service`.
- The built-in App Shortcut phrases continue to include the application name,
  as required by the compiled App Intents grammar. The short app-name-free
  phrase is supplied by a user-created Shortcut whose card has that exact name.
- The first physical custom-Shortcut invocation reached the action but returned
  `Это действие не разрешено`. Service and credit recording were changed to
  `.alwaysAllowed` on iPhone and Watch because they only add a validated entry
  and never reveal notes, history, totals, or reports.
- A separately signed development build proved that `.alwaysAllowed` alone was
  not sufficient: the same authorization failure remained on a cold App Intent
  launch. This excluded Shortcut privacy and intent authentication policy as
  the remaining boundary.
- The actual execution defect was dependency registration timing.
  `HourleafAppLauncher` registered the live repository/router dependencies, but
  it was constructed inside an inline `@StateObject` wrapped-value expression.
  That expression may remain lazy when App Intents starts the process in the
  background without evaluating the SwiftUI scene body.
- `HourleafApp.init()` now eagerly constructs the launcher and passes an
  injected `AppDependencyManager` through to the existing registration call.
  The iPhone App Intent can therefore resolve the exact live repository before
  any UI is built. There is still no fallback repository or second store.
- A regression test constructs `HourleafApp` with an isolated dependency
  manager and proves the repository is resolvable immediately, before the UI
  body is evaluated.
- Physical proof used `com.kikuai.hourleaf.local` and
  `com.kikuai.hourleaf.local.watchkitapp`. The production iPhone and Watch apps
  remained installed and untouched.
- One exact Siri invocation on iPhone produced exactly one durable
  `shortcut` entry. A second controlled invocation from Apple Watch produced
  exactly one more durable `shortcut` entry after Siri replied `Хорошо`.
  The source value proves the Watch ran the synced user-created Shortcut and
  then the repaired iPhone intent, rather than the native Watch app's direct
  WatchConnectivity writer.
- Spoken compound duration conversion and the unresolved runtime duration
  parameter remain covered by focused tests. No dependency, schema,
  entitlement, privacy manifest, or production Store build changed.
- GitHub CI previously completed all 53 UI tests with zero failures but was
  cancelled while `xcodebuild` was finishing at the job's 45-minute boundary.
  The job timeout is raised to 60 minutes; the test set itself is unchanged.

## Primary references

- https://support.apple.com/guide/shortcuts/run-shortcuts-with-siri-apd07c25bb38/ios
- https://support.apple.com/guide/shortcuts/run-shortcuts-from-apple-watch-apd5888b0858/ios
- https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/alwaysallowed
- https://developer.apple.com/documentation/AppIntents/ActionButtonArticle
