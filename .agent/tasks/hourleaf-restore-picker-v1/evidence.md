# Evidence

Verified on 2026-08-13 against the task-owned build-3 working tree.

## Root cause and behavior

- Build 2's archived app had no `UTExportedTypeDeclarations` entry and created
  a dynamic undeclared type from the backup filename extension.
- A focused UI reproduction proved the second of two consecutive SwiftUI
  `fileImporter` modifiers presented for CSV while the restore modifier did
  not present.
- Build 3 declares `com.kikuai.hourleaf.backup` as exported JSON with the
  `.hourleafbackup` extension and a vendor MIME type.
- Data Management now uses one importer with an explicit restore-or-CSV
  operation. The existing validated preview/confirm handlers remain separate.

## Checks

- Source and hosted-bundle document-type tests: PASS, 3/3.
- Focused Data Management UI test: PASS, 1/1. It opened and cancelled the
  restore picker, then opened and cancelled the CSV picker without an alert.
- Full `HourleafTests`: PASS, 489/489.
- Unsigned generic Release build: PASS for the iPhone app, embedded WidgetKit
  extension, and embedded Watch app.
- Packaged readback: build 3 in all three bundles; one exact backup type
  declaration; all three privacy manifests present.
- `scripts/verify-release-readiness.sh`: PASS.
- `scripts/test-verify-release-readiness.sh`: PASS, including identifier and
  filename-extension drift fixtures.
- `git diff --check`: PASS.

## Release boundary

Signed archive/upload, TestFlight processing/install, physical picker smoke,
validated restore, digest/count comparison, and Watch acceptance remain
separate release actions under GitHub Issue #3.

## Build 4 security-scope correction — 2026-08-16

- Physical build 3 reproduced a second restore-picker failure: files exported
  to Apple Preview and Brave were visible but preview returned the sanitized
  verification error before any production-store replacement.
- The picker now claims its security-scoped URL synchronously in the import
  completion callback, keeps that scope alive across the asynchronous preview,
  and releases it after preview completion. Restore validation reads only the
  URL supplied by `NSFileCoordinator`.
- Focused restore and CSV import tests: PASS, 27/27.
- Full `HourleafTests`: PASS, 489/489.
- Release-readiness guard and self-test: PASS.
- Unsigned generic Release build: PASS with iPhone, Quick Surfaces, and Watch
  bundles all at `1.0.0 (4)`.
- Retained signed archive package readback: PASS for all three bundle versions,
  nested signatures, privacy manifests, and dSYMs.
- App Store Connect upload: PASS with `Upload succeeded` and no reported upload
  errors or warnings.

Apple processing, TestFlight installation, physical Files-provider preview,
confirmed restore, post-relaunch ledger comparison, and final iPhone/Watch
acceptance remain separate gates. The Personal Team app and all recovery
copies remain preserved.

## Build 5 physical file-protection correction — 2026-08-16

- TestFlight build 4 still rejected both a fresh 21 KB backup and the known
  verified 18 KB backup before showing a restore preview.
- A disposable signed diagnostic build on the physical iPhone proved that the
  picker security scope was active and the filename extension was correct.
  The failure occurred while reading back the app-owned staging directory's
  data-protection class, before any backup bytes were decoded.
- `FileManager` returned no protection attribute on the physical device. The
  supported URL resource API returned the requested class using the equivalent
  `NSURLFileProtection...` spelling, while the existing verifier expected the
  `NSFileProtection...` spelling.
- The production reader now uses `URLResourceValues.fileProtection`,
  canonicalizes the requested `completeUntilFirstUserAuthentication` value,
  and retains the existing attribute fallback. Directory protection is applied
  with the typed `FileProtectionType` value instead of its raw string.
- Physical diagnostic readback then passed coordinated copy, checksum/decode,
  staged-store validation, and produced the expected aggregate preview for the
  known backup: 20 active entries and 1 deleted entry. No restore confirmation
  or production-store replacement was performed in the disposable app.
- Focused restore-preparation tests: PASS, 12/12.
- Full `HourleafTests`: PASS, 490/490.
- `scripts/verify-release-readiness.sh` and its self-test: PASS.
- Unsigned generic Release build: PASS with iPhone, Quick Surfaces, and Watch
  bundles all at `1.0.0 (5)`.
- Adversarial review found no data-loss or protection-bypass regression. The
  remaining gate is a signed build-5 TestFlight preview and confirmed restore
  with the production App Group, followed by post-relaunch ledger comparison.

## Build 6 empty recovery-root correction — 2026-08-16

- Build 5 uploaded and processed successfully in TestFlight with no upload
  errors or warnings; the iPhone installed `1.0.0 (5)` and retained its existing
  10-minute entry.
- Production build 5 verified the known backup and showed the expected preview
  (20 active entries, 1 deleted entry). The attempted confirmation did not
  replace the live store. A subsequent forced relaunch surfaced Hourleaf's
  protected recovery screen instead of opening uncertain data.
- Before any further action, the closed production app container and App Group
  were copied to a new private durable recovery directory. All 24 regular files
  passed exact size and SHA-256 verification. SQLite integrity is `ok`; the live
  store still contains exactly 1 entry and 1 revision.
- Readback shows an empty `RestoreRecovery` directory and no published active
  journal. The candidate staging slot remains isolated. This is consistent with
  journal arming failing while validating the recovery directory's protection,
  before store replacement.
- Build 6 canonicalizes both the URL resource value and the raw string fallback
  for the same supported `completeUntilFirstUserAuthentication` protection
  class. Unsupported values remain unchanged and therefore fail closed.
- Focused restore preparation + journal tests: PASS, 46/46.
- Full `HourleafTests`: PASS, 490/490. The first full attempt was externally
  terminated during compilation by a parallel Xcode job; the clean isolated
  rerun passed.

Remaining gate: release guard/build/archive/upload for build 6, TestFlight
installation, proof that the empty recovery root opens safely, and a complete
restore without terminating the app until it returns a verified terminal state.

## Build 7 abandoned-empty-root recovery — 2026-08-16

- TestFlight build 6 still opened the protected recovery screen. Device
  inventory confirmed that `RestoreRecovery` existed but contained no files or
  subdirectories, while the verified live SQLite store remained unchanged at
  1 entry and 1 revision.
- Startup now treats only an actual, non-symlink, empty recovery directory as
  idle. Any member, symlink, active transaction, unexpected residue, or invalid
  protected evidence remains critical and blocks store loading.
- Journal arming reapplies and verifies the required protection when reclaiming
  an empty root. Both recovery directories and journal metadata files now set
  protection with the typed `FileProtectionType` value used successfully by
  the physical staging diagnostic, rather than a raw string.
- Focused `RestoreJournalTests`: PASS, 35/35.
- Full `HourleafTests`: PASS, 491/491. The first full launch encountered a
  CoreSimulator Mach-server failure before executing tests; the same compiled
  bundle passed after rebooting the single canonical simulator.
- Release-readiness guard, guard self-test, and installer self-test: PASS.
- Unsigned generic Release build: PASS with iPhone, Quick Surfaces, and Watch
  bundles all at `1.0.0 (7)`.
- Retained signed archive readback: PASS for all three bundle versions, nested
  signatures, privacy manifests, and the host dSYM.
- App Store Connect upload: PASS with `Upload succeeded` and no reported upload
  errors or warnings.

Remaining gate: TestFlight processing/installation, proof that the existing
empty recovery root opens the unchanged one-entry ledger, and then a complete
uninterrupted restore with post-relaunch ledger comparison.

## Build 8 complete empty-root startup correction — 2026-08-16

- TestFlight build 7 still displayed the protected recovery screen while the
  production app remained unchanged and closed after observation.
- The first startup inspection correctly returned idle for the empty recovery
  root, but startup immediately called completed-transaction cleanup. That
  second read-only path still required the abandoned root's unverified
  protection and blocked before the Core Data store was opened.
- Completed-transaction cleanup now applies the same strict empty-root rule:
  only an actual non-symlink directory with zero members returns without
  protection validation. Any member proceeds through the original protection,
  root-member, and transaction validation before cleanup.
- The regression test exercises the full production startup sequence:
  inspect idle, cleanup succeeds without writing, and readback remains idle.
- Focused `RestoreJournalTests`: PASS, 35/35.
- Full `HourleafTests`: PASS, 491/491.
- Release-readiness guard, guard self-test, and installer self-test: PASS.
- Retained signed build 8 archive readback: PASS for all three bundle versions,
  nested signatures, privacy manifests, and the host dSYM.
- App Store Connect upload: PASS with no warning or error lines.

Remaining gate: TestFlight processing/installation and physical proof that the
unchanged one-entry ledger opens before any restore is attempted.

## Build 9 abandoned arming-directory correction — 2026-08-16

- TestFlight build 8 opened the normal Quick Entry screen and preserved the
  production ledger's existing 10-minute service entry. The protected recovery
  screen was gone, so the complete empty-root startup correction passed on the
  physical iPhone without data loss.
- The known 18 KB backup again produced the exact controlled preview: 20 active
  entries and 1 deleted entry. Confirmation returned to Settings without a
  visible terminal result, and History still showed only the original entry;
  this was treated as a failed restore, never as success.
- After the app returned to an interactive state, it was closed normally and
  the production container was inventoried read-only. `RestoreRecovery`
  contained one exact empty `.arming-<UUID>` directory and no journal, marker,
  candidate, or store-replacement artifact. The live store was therefore not
  replaced; failure occurred after creating the pre-publication transaction
  directory and before writing either metadata file.
- New recovery directories are now created with Foundation's native typed file
  protection attribute in the creation call and then verified. Startup accepts
  only an exact, non-symlink, empty `.arming-<UUID>` directory as an abandoned
  pre-publication reservation. Mutating cleanup removes only that empty shape
  with atomic `rmdir`; any nonempty directory, unexpected member, symlink, or
  protection mismatch remains critical and untouched.
- Focused `RestoreJournalTests`: PASS, 37/37, including the physical startup
  sequence and a fail-closed nonempty control.
- Full `HourleafTests`: PASS, 493/493.
- Release-readiness guard, guard self-test, and installer self-test: PASS.
- A bounded read-only lazy-senior review selected the same platform-native,
  exact-empty cleanup approach and rejected recursive deletion or widening the
  accepted recovery shapes.

Remaining gate: signed build 9 archive/upload, TestFlight installation, then one
uninterrupted 20-active-plus-1-deleted restore followed by relaunch and ledger
comparison. The Personal Team app and all durable recovery copies remain
preserved.
