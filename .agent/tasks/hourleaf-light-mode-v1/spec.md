# Hourleaf light appearance v1

## Original task

Add a light appearance to Hourleaf.

## Frozen product interpretation

Hourleaf already uses semantic system colors and can render in the iPhone's
light appearance. The missing user-facing capability is an explicit, minimal
appearance choice inside the app. Add a three-way preference:

- Follow iPhone (default)
- Light
- Dark

The choice applies immediately to the entire iPhone app and persists locally.
The Watch app and widgets continue to follow their system appearance.

## Acceptance criteria

- **AC1** — A fresh install defaults to following the iPhone appearance; no
  existing user is forced from their current system-selected appearance.
- **AC2** — Settings exposes one concise appearance picker with Follow iPhone,
  Light, and Dark options in English, Russian, and Ukrainian.
- **AC3** — Selecting Light or Dark immediately applies that appearance to all
  launch states and main iPhone screens, and the choice persists across app
  relaunches.
- **AC4** — Light appearance keeps Quick Entry, History, Progress, Settings,
  Data Management, report review, and the saved confirmation readable and
  reachable; the brand accent remains `#4A6DA7`.
- **AC5** — Watch and widget targets retain adaptive system styling and are not
  forced to the iPhone preference.
- **AC6** — Localization parity, relevant unit/UI tests, release-readiness
  guard, and a no-sign build pass with fresh evidence.

## Constraints

- iOS 17 minimum; Swift 6 and SwiftUI.
- No third-party dependency, analytics, account, network call, or data model
  migration.
- Store the appearance as a local presentation preference, not ledger data.
- Preserve the currently submitted App Store build; this change is for the
  next update.
- Reuse one canonical iPhone simulator and disposable `mktemp` build artifacts.

## Non-goals

- Synchronizing appearance between iPhone and Watch.
- Adding custom color themes or changing the brand accent.
- Restyling every screen beyond fixes required for semantic light/dark colors.
- Withdrawing or replacing the App Store version currently in review.

## Verification plan

1. Unit-test preference parsing/default/color-scheme mapping.
2. UI-test the three settings choices, immediate application, persistence, and
   critical light-mode surfaces.
3. Check EN/RU/UK localization key and placeholder parity.
4. Run the release-readiness guard.
5. Build all app targets without signing using a disposable DerivedData root.
6. Perform a fresh verifier pass against every AC before finalization.
