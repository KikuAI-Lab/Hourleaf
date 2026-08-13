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
