# Open verification problem

## AC9 — production voice write is unproven

- Why: the canonical synced Shortcut route was repaired after the owner's last
  failed service attempt. No subsequent owner voice invocation has been
  confirmed, and build 16 is not yet installed.
- Reproduction: on the physical iPhone, say `Запиши служение`, answer `одна`
  when asked for minutes, then wait for Siri's completion response.
- Expected: exactly one new production service entry for one minute with source
  `shortcut`; no credit entry and no success response before the write commits.
- Actual: not observed after the route repair.
- Smallest safe next action: run the one controlled voice invocation, then copy
  the production container read-only and compare the durable ledger. After an
  owner-authorized build 16 install, repeat once to verify the explicit minute
  prompt from the new binary.
