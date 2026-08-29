# Sanitized build 17 physical acceptance

- Physical platform: iPhone 15 Pro, iOS 26.6, Hourleaf 1.0.4 (17) from the
  processed internal TestFlight build.
- TestFlight replaced build 16 in place. A read-only before/after ledger
  comparison found no changed pre-existing row.
- The Russian service action asked for minutes and persisted exactly one
  3-minute service entry with the `shortcut` source.
- The Russian credit action asked for minutes and persisted exactly one
  4-minute credit entry with the `shortcut` source.
- No pre-existing row changed during either action.
- A system crash-log snapshot was captured immediately before the Siri actions
  and another after both persistence results were verified. The comparison
  contained no new Hourleaf crash file and therefore no new `RUNNINGBOARD`
  `0xdead10cc` termination.
- On 2026-08-29 the owner explicitly chose to keep the diagnostic and canary
  entries. No cleanup deletion or direct database mutation was performed.
- Raw databases, ledger totals, record identifiers, device identifiers, and
  crash reports remain private local evidence and are not committed.
