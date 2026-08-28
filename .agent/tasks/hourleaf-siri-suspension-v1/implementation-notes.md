# Implementation notes

The build 16 Siri actions persisted correctly, but each run produced an iOS `RUNNINGBOARD` termination with code `0xdead10cc`. The production fix must address persistence-resource lifetime rather than changing the intent's user-facing result.

lazy-senior check:
- lower rung: use UIKit's native background assertion around the existing short App Group lock
- GitHub prior art: skipped because this is a repo-local regression and Apple documents the exact termination and API
- new code justified: expiration and normal completion must balance one assertion without changing the shared file protocol

Focused verification on 2026-08-28:
- canonical iPhone 17 / iOS 26.5 simulator
- 38 selected App Intent and quick-surface lifecycle tests passed with zero failures
- coverage includes normal completion, expiration-before-activation, invalid task grants, sidecar failure, and publish/readback while the execution activity is held
- release guard and its mutation self-test passed before the focused run

Full verification on 2026-08-28:
- 523 unit and integration tests passed with zero failures after the final expiration-path test was added
- 53 non-screenshot UI tests passed with zero failures
- the UI run included quick-surface stop/review/save/discard, timer persistence across termination and relaunch, data management, history, reports, reminders, accessibility sizes, reduced motion, and EN/RU/UK launches

Adversarial review claim: the new assertion must cover every `flock` operation reached by the post-Siri reconciliation and must end exactly once without changing the extension or ledger writer. No actionable source finding remains after inspecting both call paths and failure paths. The residual gap is physical suspension behavior, which requires a new signed TestFlight build and fresh crash-log comparison.
