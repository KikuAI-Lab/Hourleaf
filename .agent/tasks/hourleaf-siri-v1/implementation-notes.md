# Implementation notes

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
