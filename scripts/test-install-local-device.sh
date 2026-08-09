#!/bin/zsh

set -euo pipefail
umask 077

fail() {
    print -u2 -- "Installer self-test failed: $1"
    exit 1
}

script_path="${0:A}"
repo_root="${script_path:h:h}"
installer="${repo_root}/scripts/install-local-device.sh"
[[ -x "$installer" ]] || fail "installer is not executable"
zsh -n "$installer" "$script_path" || fail "shell syntax check failed"
grep -Fq -- 'device info files' "$installer" \
    || fail "installer does not enumerate the app-data inventory"
grep -Fq -- 'device info processes' "$installer" \
    || fail "installer does not inspect running device processes"
grep -Fq -- '--recurse' "$installer" \
    || fail "installer does not request recursive app-data inventory"
if grep -Fq -- '--source .' "$installer"; then
    fail "installer still attempts a whole-container directory copy"
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/hourleaf-installer-test.XXXXXX")"
cleanup() {
    if [[ -d "$temporary_root" && "${temporary_root:t}" == hourleaf-installer-test.* ]]; then
        rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT

fixture_root="$temporary_root/repo"
state_root="$temporary_root/state"
stdout_file="$temporary_root/stdout"
stderr_file="$temporary_root/stderr"
fixture_installer="$fixture_root/scripts/install-local-device.sh"

copy_fixture() {
    mkdir -p \
        "$fixture_root/Hourleaf.xcodeproj" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel" \
        "$fixture_root/scripts"
    cp -- "$repo_root/Hourleaf.xcodeproj/project.pbxproj" \
        "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
    cp -- "$repo_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel/contents" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel/contents"
    cp -- "$repo_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel/contents" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel/contents"
    cp -- "$installer" "$fixture_installer"
    chmod +x "$fixture_installer"
    : > "$fixture_root/.hourleaf-installer-fixture"
}

reset_state() {
    if [[ -d "$state_root" ]]; then
        rm -rf -- "$state_root"
    fi
    mkdir -p "$state_root/app-data/Documents"
    print '{"result":{"passcodeRequired":false}}' > "$state_root/lock-state.json"
    print '{"result":{"apps":[{"bundleIdentifier":"com.kikuai.hourleaf.local"}]}}' \
        > "$state_root/apps.json"
    print '{"result":{"runningProcesses":[]}}' > "$state_root/processes.json"
    print -r -- "ledger fixture" > "$state_root/app-data/Documents/ledger.sqlite"
    print -r -- '{"records":12,"totals":120}' > "$state_root/app-data/metadata.json"
    local ledger_size metadata_size
    ledger_size="$(stat -f '%z' "$state_root/app-data/Documents/ledger.sqlite")"
    metadata_size="$(stat -f '%z' "$state_root/app-data/metadata.json")"
    print -r -- "{\"result\":{\"files\":[{\"name\":\".\",\"relativePath\":\".\",\"resources\":{\"isDirectory\":true,\"isReadable\":true,\"isWritable\":true},\"metadata\":{\"size\":0}},{\"name\":\"Documents\",\"relativePath\":\"Documents\",\"resources\":{\"isDirectory\":true,\"isReadable\":true,\"isWritable\":true},\"metadata\":{\"size\":0}},{\"name\":\"ledger.sqlite\",\"relativePath\":\"Documents/ledger.sqlite\",\"resources\":{\"isDirectory\":false,\"isReadable\":true,\"isWritable\":true},\"metadata\":{\"size\":$ledger_size}},{\"name\":\"metadata.json\",\"relativePath\":\"metadata.json\",\"resources\":{\"isDirectory\":false,\"isReadable\":true,\"isWritable\":true},\"metadata\":{\"size\":$metadata_size}}]}}" \
        > "$state_root/files.json"
}

set_apps_absent() {
    print '{"result":{"apps":[]}}' > "$state_root/apps.json"
}

set_device_locked() {
    print '{"result":{"passcodeRequired":true}}' > "$state_root/lock-state.json"
}

set_process_running() {
    print '{"result":{"runningProcesses":[{"processIdentifier":1234,"executable":"file:////private/var/containers/Bundle/Application/fixture/Hourleaf.app/Hourleaf"}]}}' \
        > "$state_root/processes.json"
}

set_process_running_on_second_read() {
    print '{"result":{"runningProcesses":[{"processIdentifier":1234,"executable":"file:////private/var/containers/Bundle/Application/fixture/Hourleaf.app/Hourleaf"}]}}' \
        > "$state_root/processes-second.json"
}

inventory_entry() {
    print -r -- "{\"name\":\"$1\",\"relativePath\":\"$2\",\"resources\":{\"isDirectory\":false,\"isReadable\":true,\"isWritable\":true},\"metadata\":{\"size\":$3}}"
}

directory_entry() {
    print -r -- "{\"name\":\"$1\",\"relativePath\":\"$2\",\"resources\":{\"isDirectory\":true,\"isReadable\":true,\"isWritable\":true}}"
}

set_inventory() {
    print -r -- "{\"result\":{\"files\":[$1]}}" > "$state_root/files.json"
}

run_installer() {
    : > "$stdout_file"
    : > "$stderr_file"
    if env \
        HOURLEAF_INSTALLER_TEST_MODE=1 \
        HOURLEAF_INSTALLER_TEST_STATE_ROOT="$state_root" \
        "$fixture_installer" AAAAAAAAAA fixture-device "$@" \
        >"$stdout_file" 2>"$stderr_file"; then
        last_status=0
    else
        last_status=$?
    fi
}

assert_success() {
    (( last_status == 0 )) || fail "expected success, got $last_status: $(<"$stderr_file")"
}

assert_failure() {
    (( last_status != 0 )) || fail "expected failure, but installer succeeded"
}

assert_stdout() {
    grep -Fq -- "$1" "$stdout_file" \
        || fail "stdout did not contain '$1': $(<"$stdout_file")"
}

assert_stderr() {
    grep -Fq -- "$1" "$stderr_file" \
        || fail "stderr did not contain '$1': $(<"$stderr_file")"
}

assert_no_runtime_values() {
    [[ ! -s "$stdout_file" || ! "$(<"$stdout_file")" == *"$state_root"* ]] \
        || fail "stdout exposed a fixture path"
    [[ ! -s "$stdout_file" || ! "$(<"$stdout_file")" == *fixture-device* ]] \
        || fail "stdout exposed a device identifier"
}

assert_no_build_receipt() {
    [[ ! -e "$state_root/build-install-skipped" ]] \
        || fail "build/install receipt was emitted after a failed guard"
}

assert_temp_clean() {
    [[ -z "$(find "$state_root" -maxdepth 1 -type d -name 'build.*' -print -quit)" ]] \
        || fail "temporary build root survived cleanup"
}

assert_manifest() {
    local backup_dir="$1"
    [[ -f "$backup_dir/SHA256SUMS" ]] \
        || fail "durable backup is missing its SHA-256 manifest"
    [[ "$(stat -f '%Lp' "$backup_dir" 2>/dev/null)" == "700" ]] \
        || fail "durable backup directory is not private"
    [[ "$(stat -f '%Lp' "$backup_dir/SHA256SUMS" 2>/dev/null)" == "600" ]] \
        || fail "SHA-256 manifest is not private"
    (cd "$backup_dir" && shasum -a 256 -c SHA256SUMS >/dev/null) \
        || fail "durable backup manifest did not reread successfully"
}

copy_fixture

# Existing standard bundle: protect, verify, then proceed to the mocked build receipt.
reset_state
run_installer
assert_success
assert_stdout "Hourleaf update: standard bundle com.kikuai.hourleaf.local"
assert_stdout "Protecting existing Hourleaf data"
assert_stdout "Verified SHA-256 manifest before build/install (2 regular files)."
assert_stdout "Fixture mode: build, install, and launch skipped."
assert_no_runtime_values
verified_line="$(grep -n 'Verified SHA-256 manifest before build/install' "$stdout_file" | cut -d: -f1)"
fixture_line="$(grep -n 'Fixture mode: build, install, and launch skipped' "$stdout_file" | cut -d: -f1)"
(( verified_line < fixture_line )) || fail "build receipt preceded manifest verification"
backup_dir="$(<"$state_root/last-backup-dir")"
[[ -n "$backup_dir" && "$backup_dir" != "$state_root/build."* ]] \
    || fail "backup was not outside the temporary build root"
assert_manifest "$backup_dir"
assert_temp_clean

# A running standard app must be closed before SQLite/WAL files are copied.
reset_state
set_process_running
run_installer
assert_failure
assert_stderr "Close Hourleaf on the iPhone"
assert_no_build_receipt
[[ ! -e "$state_root/last-backup-dir" ]] || fail "running app triggered a backup"
assert_temp_clean

# A malformed process-state response must not be treated as an empty process list.
reset_state
print '{"result":{"runningProcesses":[{"processIdentifier":"unknown","executable":"file:////private/Hourleaf.app/Hourleaf"}]}}' \
    > "$state_root/processes.json"
run_installer
assert_failure
assert_stderr "missing its process identifier"
assert_no_build_receipt
[[ ! -e "$state_root/last-backup-dir" ]] || fail "malformed process state triggered a backup"
assert_temp_clean

reset_state
print '{"result":{"runningProcesses":[{"processIdentifier":1234,"executable":123}]}}' \
    > "$state_root/processes.json"
run_installer
assert_failure
assert_stderr "missing its executable"
assert_no_build_receipt
[[ ! -e "$state_root/last-backup-dir" ]] || fail "malformed executable triggered a backup"
assert_temp_clean

reset_state
print '{not-json}' > "$state_root/processes.json"
run_installer
assert_failure
assert_stderr "process-state response was not valid JSON"
assert_no_build_receipt
[[ ! -e "$state_root/last-backup-dir" ]] || fail "invalid process JSON triggered a backup"
assert_temp_clean

# A relaunch during the per-file copy must fail before manifest verification.
reset_state
set_process_running_on_second_read
run_installer
assert_failure
assert_stderr "Close Hourleaf on the iPhone"
assert_no_build_receipt
[[ ! -e "$state_root/last-backup-dir" ]] || fail "raced process state was marked as verified"
[[ -z "$(find "$state_root/backups" -name SHA256SUMS -print -quit 2>/dev/null)" ]] \
    || fail "raced process state produced a manifest"
assert_temp_clean

# An absent app must skip copying even if the mock copy operation would fail.
reset_state
set_apps_absent
: > "$state_root/copy-fails"
run_installer
assert_success
assert_stdout "No existing com.kikuai.hourleaf.local installation detected"
[[ ! -e "$state_root/last-backup-dir" ]] || fail "absent app triggered a backup"
[[ ! -d "$state_root/backups" ]] || fail "absent app created a durable backup directory"
assert_temp_clean

# A copy failure must stop before the mocked build receipt.
reset_state
: > "$state_root/copy-fails"
run_installer
assert_failure
assert_stderr "could not copy a readable app-data file"
assert_no_build_receipt
assert_temp_clean

# A changed copied byte must fail SHA-256 verification before the mocked build.
reset_state
: > "$state_root/corrupt-copy"
run_installer
assert_failure
assert_stderr "SHA-256 manifest verification failed"
assert_no_build_receipt
assert_temp_clean

# A copied byte-count mismatch must fail before hashing/build receipt.
reset_state
: > "$state_root/size-mismatch"
run_installer
assert_failure
assert_stderr "file size does not match the device inventory"
assert_no_build_receipt
assert_temp_clean

# An unreadable installed-apps response must not be treated as an absent app.
reset_state
print '{not-json}' > "$state_root/apps.json"
run_installer
assert_failure
assert_stderr "installed-apps response was not valid JSON"
assert_no_build_receipt
assert_temp_clean

# A syntactically valid but ambiguous installed-apps array must not look absent.
reset_state
print '{"result":{"apps":["not-an-app-object"]}}' > "$state_root/apps.json"
run_installer
assert_failure
assert_stderr "missing its bundle identifier"
assert_no_build_receipt
assert_temp_clean

# A failed inventory query must stop before any per-file copy.
reset_state
: > "$state_root/files-fails"
run_installer
assert_failure
assert_stderr "could not enumerate the existing app data container"
assert_no_build_receipt
assert_temp_clean

# Every array item must be validated; a primitive item cannot be silently ignored.
reset_state
set_inventory '"not-an-inventory-object"'
run_installer
assert_failure
assert_stderr "missing name"
assert_no_build_receipt
assert_temp_clean

# Traversal paths, duplicate paths, and file/child collisions are rejected before copy.
reset_state
set_inventory "$(inventory_entry escape ../escape 15)"
run_installer
assert_failure
assert_stderr "traversal path"
assert_no_build_receipt
assert_temp_clean

reset_state
set_inventory "$(inventory_entry ledger.sqlite Documents/ledger.sqlite 15),$(inventory_entry ledger.sqlite Documents/ledger.sqlite 15)"
run_installer
assert_failure
assert_stderr "duplicate file path"
assert_no_build_receipt
assert_temp_clean

reset_state
set_inventory "$(inventory_entry foo foo 15),$(inventory_entry bar foo/bar 15)"
run_installer
assert_failure
assert_stderr "file and child-path collision"
assert_no_build_receipt
assert_temp_clean

reset_state
set_inventory "$(inventory_entry foo foo 15),$(directory_entry bar foo/bar)"
run_installer
assert_failure
assert_stderr "file and child-path collision"
assert_no_build_receipt
assert_temp_clean

reset_state
set_inventory "$(inventory_entry dot .. 15)"
run_installer
assert_failure
assert_stderr "traversal path"
assert_no_build_receipt
assert_temp_clean

# Missing or non-boolean inventory metadata is ambiguous and fails closed.
reset_state
print -r -- '{"result":{"files":[{"name":"ledger.sqlite","relativePath":"Documents/ledger.sqlite","resources":{"isDirectory":false,"isReadable":"unknown","isWritable":true},"metadata":{"size":15}}]}}' \
    > "$state_root/files.json"
run_installer
assert_failure
assert_stderr "missing resources.isReadable"
assert_no_build_receipt
assert_temp_clean

reset_state
print -r -- '{"result":{"files":[{"name":"ledger.sqlite","relativePath":"Documents/ledger.sqlite","resources":{"isDirectory":"false","isReadable":true,"isWritable":true},"metadata":{"size":15}}]}}' \
    > "$state_root/files.json"
run_installer
assert_failure
assert_stderr "missing resources.isDirectory"
assert_no_build_receipt
assert_temp_clean

reset_state
print -r -- '{"result":{"files":[{"name":123,"relativePath":123,"resources":{"isDirectory":false,"isReadable":true,"isWritable":true},"metadata":{"size":"15"}}]}}' \
    > "$state_root/files.json"
run_installer
assert_failure
assert_stderr "missing name"
assert_no_build_receipt
assert_temp_clean

# A copied special file must not be accepted as a regular-file backup.
reset_state
: > "$state_root/special-copy"
run_installer
assert_failure
assert_stderr "non-regular copied item"
assert_no_build_receipt
assert_temp_clean

# A locked device must stop before any app-data protection or build receipt.
reset_state
set_device_locked
run_installer
assert_failure
assert_stderr "Unlock the iPhone and keep its screen on"
[[ ! -e "$state_root/last-backup-dir" ]] || fail "locked device triggered a backup"
assert_no_build_receipt
assert_temp_clean

# A string that looks like a boolean is not a trustworthy lock-state response.
reset_state
print '{"result":{"passcodeRequired":"false"}}' > "$state_root/lock-state.json"
run_installer
assert_failure
assert_stderr "did not contain result.passcodeRequired"
[[ ! -e "$state_root/last-backup-dir" ]] || fail "malformed lock state triggered a backup"
assert_no_build_receipt
assert_temp_clean

# Smoke is a distinct bundle and never looks up or copies the standard container.
reset_state
: > "$state_root/copy-fails"
print '{not-json}' > "$state_root/processes.json"
run_installer --slice3-smoke
assert_success
assert_stdout "Hourleaf Shortcut Smoke installation: disposable bundle com.kikuai.hourleaf.slice3smoke"
assert_stdout "standard Hourleaf data is untouched"
assert_stdout "Hourleaf Shortcut Smoke installation completed"
assert_no_runtime_values
[[ ! -e "$state_root/last-backup-dir" ]] || fail "smoke flow created a standard backup"
[[ ! -d "$state_root/backups" ]] || fail "smoke flow touched the durable backup directory"
assert_temp_clean

print "Installer self-test passed."
