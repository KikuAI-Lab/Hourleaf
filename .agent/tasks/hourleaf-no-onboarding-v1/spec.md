# Hourleaf no-onboarding release fix

Class: temporary task artifact. GitHub Issue #3 owns release state; code and
tests own the accepted behavior. Keep this bundle as cold proof after PASS.

## Goal

Remove the blocking first-launch onboarding screen so a new Hourleaf install
opens directly into Quick Entry with zero defaults.

## Acceptance criteria

- **AC1:** A fresh install reaches the normal tab interface and Quick Entry
  without showing or requiring an onboarding action.
- **AC2:** The removed screen's source and user-facing localization copy are no
  longer shipped.
- **AC3:** Existing persisted and portable-backup fields for baseline minutes,
  carry-in minutes, and `onboardingComplete` remain readable and restorable;
  this release fix makes no Core Data or backup-format migration.
- **AC4:** UI coverage proves a fresh English install opens Quick Entry and
  remains usable at Accessibility XXXL without onboarding UI.
- **AC5:** Build 2 compiles, release-readiness checks pass, and the repository
  remains clean enough to commit and publish the task-owned change.

## Constraints

- Preserve the old Personal Team app and both verified recovery backups.
- Do not restore or delete data while implementing this UI-only change.
- Keep iOS 17, Swift 6, current signing IDs, Watch target, widget target, and
  portable backup V1 unchanged.
- Reuse the canonical iPhone simulator only; create no new simulators.

## Non-goals

- Redesign Settings or Progress.
- Remove legacy persistence fields.
- Change reporting/accounting behavior.
- Submit the App Store version for review.

## Verification plan

1. Static scans and localization parity/lint.
2. Focused fresh-install UI tests in normal and Accessibility XXXL sizes.
3. Focused unit tests for persistence/backup compatibility if affected.
4. Release-readiness guard and generic no-sign build.
5. Fresh diff/status review before commit and upload.
