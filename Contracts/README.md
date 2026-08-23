# Hourleaf portable contracts

This directory contains small, versioned, platform-neutral fixtures for
implementations that reproduce Hourleaf's local report, service-year, and
backup behavior. The fixtures are anonymized and contain no account, device,
tracking, or iCloud data.

`report-service-year-fixtures-v1.json` uses `schemaVersion: 1` and keeps
inputs and expected outputs explicit. Monthly report cases use `service` and
`credit` minute ledgers; service-year cases use dated entries and a baseline;
formatter cases use a language code (`en`, `ru`, or `uk`) and expected text.
Each service-year case's `serviceYearContainingDate` selects the September
through August service year that contains that date. It is not an entry cutoff:
it does not mean that entries after that date are excluded from the selected
service year.
Future Android tests can decode the document with ordinary JSON tooling
without importing Swift types.

`canonical-backup-v2.hourleafbackup` is the canonical V2 JSON byte fixture for
the existing Hourleaf backup codec test oracle. It is intentionally checked in
with its `.hourleafbackup` filename so consumers exercise the same portable
backup boundary. The Swift test verifies exact bytes, the 3,426-byte size,
checksum, and strict `decodeAndVerify` behavior. The fixture intentionally
preserves the legacy raw policy field `carryAcrossServiceYear: true` from the
golden codec data; that storage value is compatibility evidence. Monthly
report parity is separate and resets both service and credit carries at
September.

These files describe compatibility cases; production behavior remains owned by
the Hourleaf source and its tests.
