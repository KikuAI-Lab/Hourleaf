# Sanitized build 16 diagnosis

- Physical platform: iPhone 15 Pro, iOS 26.6, Hourleaf 1.0.4 (16).
- Two intentional Siri actions produced exactly two new active ledger entries and two matching create revisions: one service entry and one credit entry, each with the requested minute value and `shortcut` source.
- Both post-action databases passed SQLite integrity checks. No raw row values, object identifiers, device identifiers, or personal ledger totals are retained here.
- Each action was followed by a separate `RUNNINGBOARD` `SIGKILL` with termination code `0xdead10cc`.
- Symbolication with the matching retained build 16 dSYM placed both terminations in the shared quick-surface file lock during host-app reconciliation. One path was launched by the scene-phase refresh and the other by the ledger-change refresh.
- The evidence therefore identifies a post-persistence suspension race, not a failed or duplicated Siri write.
