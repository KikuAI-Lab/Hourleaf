# Hourleaf restore-picker release fix

Class: temporary task artifact. GitHub Issue #3 owns release state; code and
tests own accepted behavior. Keep this bundle as cold proof after PASS.

## Goal

Make the production iPhone build reliably present Files for Hourleaf portable
backups, then use the existing validated restore coordinator to migrate the
verified Personal Team ledger into the production TestFlight app.

## Acceptance criteria

- **AC1:** Hourleaf declares one stable exported document type for
  `.hourleafbackup`, conforming to `public.json` and represented in Files.
- **AC2:** The restore file importer filters by that declared type and presents
  on a physical production build; CSV import remains independent.
- **AC3:** Automated checks prove the source type, packaged Info.plist
  declaration, and restore-picker presentation contract.
- **AC4:** A signed TestFlight build restores the already verified portable
  backup only through `HourleafRestoreCoordinator`.
- **AC5:** Post-restore readback matches the source backup's authoritative
  counts and records digest before any old app or recovery copy is removed.

## Constraints

- Preserve the old Personal Team app, both raw container recovery copies, and
  the verified portable backup.
- Do not copy or edit Core Data/SQLite files directly.
- Do not weaken restore validation, revision-graph validation, or whole-store
  replacement safeguards.
- Reuse the canonical iPhone simulator only; create no new simulators.
- Do not submit for App Review or make owner-only legal/release choices.

## Verification plan

1. Physical build-2 reproduction and source/packaged metadata diagnosis.
2. Static Info.plist/type-contract tests and focused Data Management UI test.
3. Backup/restore unit suite, full unit suite, readiness guards, Release build.
4. Skeptical diff review.
5. Signed archive/upload/install, physical picker smoke, validated restore, and
   exact post-restore comparison.
