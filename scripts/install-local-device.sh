#!/bin/zsh

set -euo pipefail
umask 077

usage() {
    print -u2 "Usage: install-local-device.sh <personal-team-id> <device-id> [--slice3-smoke|--without-app-group]"
    exit 64
}

fail() {
    print -u2 -- "Hourleaf local installer failed: $1"
    exit "${2:-65}"
}

if (( $# != 2 && $# != 3 )); then
    usage
fi
if (( $# == 3 )) && [[ "$3" != "--slice3-smoke" && "$3" != "--without-app-group" ]]; then
    usage
fi

personal_team_id="$1"
device_id="$2"
repo_root="${0:A:h:h}"
production_bundle_id="com.kikuai.hourleaf"
production_extension_bundle_id="com.kikuai.hourleaf.quick-surfaces"
production_app_group_id="group.com.kikuai.hourleaf"
production_quick_entry_url_scheme="hourleaf"
standard_local_bundle_id="com.kikuai.hourleaf.local"
standard_local_extension_bundle_id="com.kikuai.hourleaf.local.quick-surfaces"
standard_local_app_group_id="group.com.kikuai.hourleaf.local"
standard_local_quick_entry_url_scheme="hourleaf-local"
slice3_smoke_bundle_id="com.kikuai.hourleaf.slice3smoke"
slice3_smoke_extension_bundle_id="com.kikuai.hourleaf.slice3smoke.quick-surfaces"
slice3_smoke_app_group_id="group.com.kikuai.hourleaf.slice3smoke"
slice3_smoke_quick_entry_url_scheme="hourleaf-slice3smoke"

if [[ "$production_bundle_id" == "$standard_local_bundle_id" \
    || "$production_bundle_id" == "$slice3_smoke_bundle_id" \
    || "$standard_local_bundle_id" == "$slice3_smoke_bundle_id" ]]; then
    fail "disposable smoke bundle identifier must differ from production and standard local builds"
fi
if [[ "$production_extension_bundle_id" == "$standard_local_extension_bundle_id" \
    || "$production_extension_bundle_id" == "$slice3_smoke_extension_bundle_id" \
    || "$standard_local_extension_bundle_id" == "$slice3_smoke_extension_bundle_id" ]]; then
    fail "disposable smoke extension identifier must differ from production and standard local builds"
fi
if [[ "$production_app_group_id" == "$standard_local_app_group_id" \
    || "$production_app_group_id" == "$slice3_smoke_app_group_id" \
    || "$standard_local_app_group_id" == "$slice3_smoke_app_group_id" ]]; then
    fail "disposable smoke App Group identifier must differ from production and standard local builds"
fi
if [[ "$production_quick_entry_url_scheme" == "$standard_local_quick_entry_url_scheme" \
    || "$production_quick_entry_url_scheme" == "$slice3_smoke_quick_entry_url_scheme" \
    || "$standard_local_quick_entry_url_scheme" == "$slice3_smoke_quick_entry_url_scheme" ]]; then
    fail "disposable quick-entry URL schemes must differ from production and standard local builds"
fi
if [[ ! "$personal_team_id" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "Invalid Apple team identifier: expected 10 uppercase letters or digits."
    exit 64
fi
if [[ -z "$device_id" || "$device_id" == *$'\n'* ]]; then
    print -u2 "Invalid device identifier: expected a non-empty device name, UDID, or serial."
    exit 64
fi

is_smoke=0
without_app_group=0
local_bundle_id="$standard_local_bundle_id"
local_extension_bundle_id="$standard_local_extension_bundle_id"
local_app_group_id="$standard_local_app_group_id"
local_quick_entry_url_scheme="$standard_local_quick_entry_url_scheme"
typeset -a local_build_settings=()
if (( $# == 3 )) && [[ "$3" == "--slice3-smoke" ]]; then
    is_smoke=1
    local_bundle_id="$slice3_smoke_bundle_id"
    local_extension_bundle_id="$slice3_smoke_extension_bundle_id"
    local_app_group_id="$slice3_smoke_app_group_id"
    local_quick_entry_url_scheme="$slice3_smoke_quick_entry_url_scheme"
    local_build_settings=("INFOPLIST_KEY_CFBundleDisplayName=Hourleaf Shortcut Smoke")
elif (( $# == 3 )) && [[ "$3" == "--without-app-group" ]]; then
    without_app_group=1
    local_build_settings=("CODE_SIGN_ENTITLEMENTS=")
fi

test_mode="${HOURLEAF_INSTALLER_TEST_MODE:-0}"
test_state_root=""
if [[ "$test_mode" == "1" ]]; then
    [[ -f "$repo_root/.hourleaf-installer-fixture" ]] \
        || fail "test mode requires a fixture marker"
    test_state_root="${HOURLEAF_INSTALLER_TEST_STATE_ROOT:-}"
    [[ -n "$test_state_root" ]] || fail "test mode requires HOURLEAF_INSTALLER_TEST_STATE_ROOT"
    mkdir -p -- "$test_state_root"
    test_state_root="${test_state_root:A}"
    temporary_root="$(mktemp -d "$test_state_root/build.XXXXXX")"
else
    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/hourleaf-local.XXXXXX")"
fi
temporary_source="$temporary_root/source"
derived_data="$temporary_root/derived-data"
device_command_log="$temporary_root/device-command.log"

cleanup() {
    if [[ -d "$temporary_root" ]]; then
        if [[ "$test_mode" == "1" || "${temporary_root:t}" == hourleaf-local.* ]]; then
            rm -rf -- "$temporary_root"
        fi
    fi
}
trap cleanup EXIT

if (( is_smoke )); then
    print "Hourleaf Shortcut Smoke installation: disposable bundle $slice3_smoke_bundle_id; standard Hourleaf data is untouched."
elif (( without_app_group )); then
    print "Hourleaf update without App Group: standard data will be protected; widgets and controls will remain unavailable."
else
    print "Hourleaf update: standard bundle $standard_local_bundle_id will be protected before build and install."
fi

lock_state_file="$temporary_root/lock-state.json"
read_lock_state() {
    if [[ "$test_mode" == "1" ]]; then
        [[ -f "$test_state_root/lock-state.json" ]] \
            || fail "mock lock-state fixture is missing"
        cp -p -- "$test_state_root/lock-state.json" "$lock_state_file" \
            || fail "could not read mock lock-state fixture"
    else
        xcrun devicectl device info lockState \
            --device "$device_id" \
            --json-output "$lock_state_file" \
            --quiet \
            >"$device_command_log" 2>&1 \
            || fail "could not read the device lock state" 69
    fi
}

read_lock_state
if ! passcode_required="$(plutil -extract result.passcodeRequired raw -expect bool -o - "$lock_state_file" 2>/dev/null)"; then
    fail "device lock-state response did not contain result.passcodeRequired" 69
fi
if [[ "$passcode_required" != "false" ]]; then
    print -u2 "Unlock the iPhone and keep its screen on, then run the installer again."
    exit 69
fi

apps_state_file="$temporary_root/apps.json"
apps_array_file="$temporary_root/apps-array.json"
processes_state_file="$temporary_root/processes.json"
processes_array_file="$temporary_root/processes-array.json"
read_installed_apps() {
    if [[ "$test_mode" == "1" ]]; then
        [[ -f "$test_state_root/apps.json" ]] \
            || fail "mock installed-apps fixture is missing"
        cp -p -- "$test_state_root/apps.json" "$apps_state_file" \
            || fail "could not read mock installed-apps fixture"
    else
        xcrun devicectl device info apps \
            --device "$device_id" \
            --bundle-id "$standard_local_bundle_id" \
            --json-output "$apps_state_file" \
            --quiet \
            >"$device_command_log" 2>&1 \
            || fail "could not determine whether the standard Hourleaf bundle is installed"
    fi
}

standard_installed=0
if (( ! is_smoke )); then
    read_installed_apps
    if ! apps_json="$(plutil -convert json -o - "$apps_state_file" 2>/dev/null)"; then
        fail "installed-apps response was not valid JSON"
    fi
    if ! plutil -extract result.apps json -o "$apps_array_file" "$apps_state_file" 2>/dev/null; then
        fail "installed-apps response did not contain result.apps"
    fi
    local apps_dump apps_shape apps_count app_index app_bundle
    if ! apps_dump="$(plutil -p "$apps_array_file" 2>/dev/null)"; then
        fail "could not read installed-apps response"
    fi
    apps_shape="${apps_dump%%$'\n'*}"
    [[ "$apps_shape" == \[* ]] || fail "installed-apps result.apps was not an array"
    apps_count="$(print -r -- "$apps_dump" | awk '/^  [0-9]+ =>/{count++} END{print count + 0}')"
    [[ "$apps_count" =~ '^[0-9]+$' ]] || fail "installed-apps array length was ambiguous"
    for (( app_index = 0; app_index < apps_count; app_index++ )); do
        if ! app_bundle="$(plutil -extract "$app_index.bundleIdentifier" raw -expect string -o - "$apps_array_file" 2>/dev/null)"; then
            fail "installed-apps item was missing its bundle identifier"
        fi
        [[ "$app_bundle" == "$standard_local_bundle_id" ]] \
            || fail "installed-apps response did not match the standard Hourleaf bundle"
        standard_installed=1
    done
fi

read_running_processes() {
    if [[ "$test_mode" == "1" ]]; then
        local process_fixture="$test_state_root/processes.json"
        if [[ -f "$test_state_root/processes-second.json" ]]; then
            local process_read_count=0
            if [[ -f "$test_state_root/processes-read-count" ]]; then
                process_read_count="$(<"$test_state_root/processes-read-count")"
                [[ "$process_read_count" =~ '^[0-9]+$' ]] \
                    || fail "mock process-state read count was ambiguous"
            fi
            if (( process_read_count > 0 )); then
                process_fixture="$test_state_root/processes-second.json"
            fi
            print -r -- "$((process_read_count + 1))" > "$test_state_root/processes-read-count"
        fi
        [[ ! -f "$test_state_root/processes-fails" ]] \
            || fail "could not determine whether Hourleaf is running"
        [[ -f "$process_fixture" ]] \
            || fail "mock process-state fixture is missing"
        cp -p -- "$process_fixture" "$processes_state_file" \
            || fail "could not read mock process-state fixture"
    else
        xcrun devicectl device info processes \
            --device "$device_id" \
            --json-output "$processes_state_file" \
            --quiet \
            >"$device_command_log" 2>&1 \
            || fail "could not determine whether Hourleaf is running"
    fi
}

guard_no_running_standard_process() {
    read_running_processes
    if ! plutil -convert json -o /dev/null "$processes_state_file" 2>/dev/null; then
        fail "process-state response was not valid JSON"
    fi
    if ! plutil -extract result.runningProcesses json -o "$processes_array_file" "$processes_state_file" 2>/dev/null; then
        fail "process-state response did not contain result.runningProcesses"
    fi
    local processes_dump processes_shape process_count process_index process_identifier executable
    if ! processes_dump="$(plutil -p "$processes_array_file" 2>/dev/null)"; then
        fail "could not read process-state response"
    fi
    processes_shape="${processes_dump%%$'\n'*}"
    [[ "$processes_shape" == \[* ]] || fail "process-state result.runningProcesses was not an array"
    process_count="$(print -r -- "$processes_dump" | awk '/^  [0-9]+ =>/{count++} END{print count + 0}')"
    [[ "$process_count" =~ '^[0-9]+$' ]] || fail "process-state array length was ambiguous"
    for (( process_index = 0; process_index < process_count; process_index++ )); do
        if ! process_identifier="$(plutil -extract "$process_index.processIdentifier" raw -expect integer -o - "$processes_array_file" 2>/dev/null)"; then
            fail "process-state item was missing its process identifier"
        fi
        [[ "$process_identifier" =~ '^[0-9]+$' && "$process_identifier" != 0 ]] \
            || fail "process-state item had an ambiguous process identifier"
        if ! executable="$(plutil -extract "$process_index.executable" raw -expect string -o - "$processes_array_file" 2>/dev/null)"; then
            fail "process-state item was missing its executable"
        fi
        [[ -n "$executable" && "$executable" != *$'\n'* ]] \
            || fail "process-state item had an ambiguous executable"
        if [[ "$executable" == */Hourleaf.app/Hourleaf ]]; then
            print -u2 "Close Hourleaf on the iPhone, then run the installer again; the standard data container must not change while it is running."
            exit 69
        fi
    done
}

path_is_within() {
    local child="${1:A}"
    local parent="${2:A}"
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

durable_backup_root=""
backup_dir=""
manifest_file=""
manifest_name="SHA256SUMS"
files_state_file=""
files_array_file=""
typeset -a expected_remote_paths=()
typeset -A expected_remote_sizes=()

ensure_backup_root() {
    if [[ "$test_mode" == "1" ]]; then
        durable_backup_root="${HOURLEAF_INSTALLER_TEST_BACKUP_ROOT:-$test_state_root/backups}"
    else
        durable_backup_root="$HOME/Library/Application Support/Hourleaf/Device Backups"
    fi
    [[ -n "$durable_backup_root" ]] || fail "durable backup directory is empty"
    [[ ! -L "$durable_backup_root" ]] \
        || fail "durable backup directory must not be a symbolic link"
    mkdir -p -- "$durable_backup_root" \
        || fail "could not create durable backup directory"
    chmod 700 "$durable_backup_root" \
        || fail "could not make durable backup directory private"
    durable_backup_root="${durable_backup_root:A}"
    if path_is_within "$durable_backup_root" "$temporary_root" \
        || path_is_within "$temporary_root" "$durable_backup_root"; then
        fail "durable backup directory must be outside the temporary build root"
    fi
}

read_file_inventory() {
    files_state_file="$temporary_root/files.json"
    files_array_file="$temporary_root/files-array.json"
    if [[ "$test_mode" == "1" ]]; then
        [[ ! -f "$test_state_root/files-fails" ]] \
            || fail "could not enumerate the existing app data container"
        [[ -f "$test_state_root/files.json" ]] \
            || fail "mock app-data inventory fixture is missing"
        cp -p -- "$test_state_root/files.json" "$files_state_file" \
            || fail "could not read mock app-data inventory fixture"
    else
        xcrun devicectl device info files \
            --device "$device_id" \
            --domain-type appDataContainer \
            --domain-identifier "$standard_local_bundle_id" \
            --recurse \
            --json-output "$files_state_file" \
            --quiet \
            >"$device_command_log" 2>&1 \
            || fail "could not enumerate the existing app data container"
    fi
    if ! plutil -extract result.files json -o "$files_array_file" "$files_state_file" 2>/dev/null; then
        fail "app-data inventory did not contain result.files"
    fi
    local inventory_dump shape
    if ! inventory_dump="$(plutil -p "$files_array_file" 2>/dev/null)"; then
        fail "could not read app-data inventory array"
    fi
    shape="${inventory_dump%%$'\n'*}"
    [[ "$shape" == \[* ]] || fail "app-data inventory result.files was not an array"
}

extract_inventory_field() {
    local file_index="$1"
    local field="$2"
    local expected_type="$3"
    local value
    if ! value="$(plutil -extract "$file_index.$field" raw -expect "$expected_type" -o - "$files_array_file" 2>/dev/null)"; then
        fail "app-data inventory item $file_index is missing $field"
    fi
    print -r -- "$value"
}

validate_relative_path() {
    local relative="$1"
    [[ -n "$relative" && "$relative" != /* && "$relative" != *$'\n'* && "$relative" != *$'\t'* ]] \
        || fail "app-data inventory contains an unsafe relative path"
    [[ "$relative" != *"//"* ]] \
        || fail "app-data inventory contains an ambiguous relative path"
    case "/$relative/" in
        */./*|*/../*)
            fail "app-data inventory contains a traversal path"
            ;;
    esac
}

prepare_expected_files() {
    read_file_inventory
    expected_remote_paths=()
    expected_remote_sizes=()

    local files_array_output file_count
    files_array_output="$(plutil -p "$files_array_file" 2>/dev/null)" \
        || fail "could not read app-data inventory array"
    file_count="$(print -r -- "$files_array_output" | awk '/^  [0-9]+ =>/{count++} END{print count + 0}')"
    [[ "$file_count" =~ '^[0-9]+$' ]] \
        || fail "app-data inventory array length was ambiguous"

    typeset -A seen_entries=()
    typeset -A seen_files=()
    local -a all_paths=()
    local root_seen=0
    local documents_root_seen=0
    local library_root_seen=0
    local temporary_root_seen=0
    local file_index name relative is_directory is_readable is_writable size normalized ancestor existing
    for (( file_index = 0; file_index < file_count; file_index++ )); do
        name="$(extract_inventory_field "$file_index" name string)"
        relative="$(extract_inventory_field "$file_index" relativePath string)"
        is_directory="$(extract_inventory_field "$file_index" resources.isDirectory bool)"
        is_readable="$(extract_inventory_field "$file_index" resources.isReadable bool)"
        is_writable="$(extract_inventory_field "$file_index" resources.isWritable bool)"
        [[ -n "$name" && "$name" != *$'\n'* && "$name" != *$'\t'* ]] \
            || fail "app-data inventory item $file_index has an ambiguous name"
        [[ "$is_directory" == true || "$is_directory" == false ]] \
            || fail "app-data inventory item $file_index has an ambiguous directory flag"
        [[ "$is_readable" == true || "$is_readable" == false ]] \
            || fail "app-data inventory item $file_index has an ambiguous readability flag"
        [[ "$is_writable" == true || "$is_writable" == false ]] \
            || fail "app-data inventory item $file_index has an ambiguous writability flag"

        if [[ "$is_directory" == true && ( -z "$relative" || "$relative" == "." ) ]]; then
            [[ "$name" == "$relative" ]] \
                || fail "app-data inventory item $file_index has mismatched name and path"
            (( root_seen == 0 )) \
                || fail "app-data inventory contains a duplicate root path"
            [[ "$is_readable" == true ]] \
                || fail "app-data inventory root is not readable"
            root_seen=1
            continue
        fi
        validate_relative_path "$relative"
        normalized="${relative#./}"
        normalized="${normalized%/}"
        [[ -n "$normalized" && "$normalized" != . ]] \
            || fail "app-data inventory contains an empty relative path"
        [[ "$name" == "$relative" ]] \
            || fail "app-data inventory item $file_index has mismatched name and path"
        [[ "$is_readable" == true ]] \
            || fail "app-data inventory contains an unreadable item"

        if (( ${+seen_entries[$normalized]} )); then
            fail "app-data inventory contains a duplicate file path"
        fi
        ancestor="$normalized"
        while [[ "$ancestor" == */* ]]; do
            ancestor="${ancestor%/*}"
            [[ -z "$ancestor" || ${+seen_files[$ancestor]} -eq 0 ]] \
                || fail "app-data inventory contains a file and child-path collision"
        done
        if [[ "$is_directory" == false ]]; then
            for existing in "${all_paths[@]}"; do
                [[ "$existing" != "$normalized/"* ]] \
                    || fail "app-data inventory contains a file and child-path collision"
            done
        fi
        seen_entries[$normalized]=1
        all_paths+=("$normalized")

        if [[ "$is_directory" == true ]]; then
            case "$normalized" in
                Documents)
                    documents_root_seen=1
                    ;;
                Library)
                    library_root_seen=1
                    ;;
                tmp)
                    temporary_root_seen=1
                    ;;
            esac
            continue
        fi
        size="$(extract_inventory_field "$file_index" metadata.size integer)"
        [[ "$size" =~ '^[0-9]+$' ]] \
            || fail "app-data inventory contains an ambiguous file size"
        [[ "$normalized" != "$manifest_name" ]] \
            || fail "app-data inventory contains the reserved $manifest_name path"
        seen_files[$normalized]=1
        expected_remote_paths+=("$normalized")
        expected_remote_sizes[$normalized]="$size"
    done
    if (( root_seen != 1 )); then
        (( documents_root_seen == 1 && library_root_seen == 1 && temporary_root_seen == 1 )) \
            || fail "app-data inventory is missing the readable app-container roots"
    fi
}

copy_inventory_file() {
    local relative="$1"
    local destination="$backup_dir/$relative"
    local destination_parent="${destination:h}"
    mkdir -p "$destination_parent" \
        || return 1
    chmod 700 "$destination_parent" \
        || return 1
    if [[ "$test_mode" == "1" ]]; then
        [[ ! -f "$test_state_root/copy-fails" ]] \
            || return 1
        [[ -f "$test_state_root/app-data/$relative" && ! -L "$test_state_root/app-data/$relative" ]] \
            || return 1
        cp -- "$test_state_root/app-data/$relative" "$destination" \
            || return 1
        return 0
    fi
    xcrun devicectl device copy from \
        --device "$device_id" \
        --domain-type appDataContainer \
        --domain-identifier "$standard_local_bundle_id" \
        --source "$relative" \
        --destination "$destination" \
        --quiet \
        >"$device_command_log" 2>&1
}

copy_existing_container() {
    prepare_expected_files
    local relative
    for relative in "${expected_remote_paths[@]}"; do
        if ! copy_inventory_file "$relative"; then
            fail "could not copy a readable app-data file"
        fi
    done
    if [[ "$test_mode" == "1" && -f "$test_state_root/size-mismatch" \
        && ${#expected_remote_paths[@]} -gt 0 ]]; then
        print -r -- "test size mismatch" >> "$backup_dir/${expected_remote_paths[1]}"
    fi
    if [[ "$test_mode" == "1" && -f "$test_state_root/special-copy" ]]; then
        mkfifo "$backup_dir/remote-special" \
            || fail "could not create mock special-file fixture"
    fi
}

collect_regular_files() {
    typeset -a collected=()
    local file_list="$temporary_root/regular-files.nul"
    local file_path
    if ! find "$backup_dir" -type f ! -path "$manifest_file" -print0 > "$file_list"; then
        fail "could not enumerate copied regular files"
    fi
    while IFS= read -r -d '' file_path; do
        [[ "$file_path" != *$'\n'* ]] \
            || fail "app data contains a file path with a newline"
        collected+=("$file_path")
    done < "$file_list"
    if (( ${#collected[@]} > 0 )); then
        printf '%s\n' "${collected[@]}" | sort
    fi
}

verify_expected_files() {
    manifest_file="$backup_dir/$manifest_name"
    typeset -a actual_paths=()
    local file_path relative destination expected_size actual_size
    while IFS= read -r file_path; do
        relative="${file_path#$backup_dir/}"
        actual_paths+=("$relative")
    done < <(collect_regular_files)
    if (( ${#expected_remote_paths[@]} != ${#actual_paths[@]} )); then
        fail "copied app-data file list does not match the device inventory"
    fi
    for relative in "${expected_remote_paths[@]}"; do
        destination="$backup_dir/$relative"
        [[ -f "$destination" && ! -L "$destination" ]] \
            || fail "copied app-data item is missing or non-regular"
        expected_size="${expected_remote_sizes[$relative]}"
        if ! actual_size="$(stat -f '%z' "$destination" 2>/dev/null)"; then
            fail "could not read copied app-data file size"
        fi
        [[ "$actual_size" == "$expected_size" ]] \
            || fail "copied app-data file size does not match the device inventory"
    done
    if (( ${#expected_remote_paths[@]} > 0 )); then
        local expected_listing actual_listing
        expected_listing="$(printf '%s\n' "${expected_remote_paths[@]}" | sort)"
        actual_listing="$(printf '%s\n' "${actual_paths[@]}" | sort)"
        [[ "$expected_listing" == "$actual_listing" ]] \
            || fail "copied app-data file list does not match the device inventory"
    fi
}

build_manifest() {
    manifest_file="$backup_dir/$manifest_name"
    [[ ! -e "$manifest_file" && ! -L "$manifest_file" ]] \
        || fail "app data contains the reserved $manifest_name path"
    : > "$manifest_file" \
        || fail "could not create SHA-256 manifest"
    chmod 600 "$manifest_file" \
        || fail "could not make SHA-256 manifest private"

    local unsupported
    if ! unsupported="$(find "$backup_dir" ! -type d ! -type f -print -quit)"; then
        fail "could not inspect copied app data"
    fi
    [[ -z "$unsupported" ]] \
        || fail "app data contains a non-regular copied item"

    typeset -a regular_files=()
    local file_path hash relative
    while IFS= read -r file_path; do
        regular_files+=("$file_path")
    done < <(collect_regular_files)
    for file_path in "${regular_files[@]}"; do
        relative="./${file_path#$backup_dir/}"
        hash="$(shasum -a 256 -- "$file_path" | awk '{print $1}')"
        [[ "$hash" =~ '^[[:xdigit:]]{64}$' ]] \
            || fail "could not hash a copied app-data file"
        print -r -- "$hash  $relative" >> "$manifest_file"
    done
    if [[ "$test_mode" == "1" && -f "$test_state_root/corrupt-copy" ]]; then
        local first_file
        first_file="$(find "$backup_dir" -type f ! -path "$manifest_file" -print -quit)"
        [[ -n "$first_file" ]] || fail "mock corruption fixture has no regular file"
        print -r -- "test corruption" >> "$first_file"
    fi
    chmod 600 "$manifest_file" \
        || fail "could not make SHA-256 manifest private"
    if ! (cd "$backup_dir" && shasum -a 256 -c "$manifest_file" >/dev/null 2>&1); then
        fail "SHA-256 manifest verification failed"
    fi
}

protect_existing_container() {
    guard_no_running_standard_process
    ensure_backup_root
    backup_dir="$(mktemp -d "$durable_backup_root/hourleaf-standard-local.XXXXXX")" \
        || fail "could not create a durable backup directory"
    manifest_file="$backup_dir/$manifest_name"
    chmod 700 "$backup_dir" \
        || fail "could not make durable backup directory private"
    if path_is_within "$backup_dir" "$temporary_root" \
        || path_is_within "$temporary_root" "$backup_dir"; then
        fail "durable backup directory must be outside the temporary build root"
    fi

    print "Protecting existing Hourleaf data in a durable private backup."
    if ! copy_existing_container; then
        fail "could not protect the existing $standard_local_bundle_id app data container"
    fi
    guard_no_running_standard_process
    verify_expected_files
    build_manifest
    print "Verified SHA-256 manifest before build/install (${#expected_remote_paths[@]} regular files)."
    if [[ "$test_mode" == "1" ]]; then
        print -r -- "$backup_dir" > "$test_state_root/last-backup-dir"
    fi
}

if (( ! is_smoke && standard_installed )); then
    protect_existing_container
elif (( ! is_smoke )); then
    print "No existing $standard_local_bundle_id installation detected; no data backup was needed."
fi

rsync -a \
    --exclude .git \
    --exclude .DS_Store \
    --exclude build \
    "$repo_root/" \
    "$temporary_source/"

project_file="$temporary_source/Hourleaf.xcodeproj/project.pbxproj"
entitlements_file="$temporary_source/Hourleaf/Hourleaf.entitlements"
extension_entitlements_file="$temporary_source/HourleafQuickSurfaces/HourleafQuickSurfaces.entitlements"
typeset -a model_files=()
while IFS= read -r model_file; do
    model_files+=("$model_file")
done < <(find "$temporary_source" -type f -path '*.xcdatamodel/contents' -print | sort)

if grep -Eq 'com\.apple\.(iCloud|Push) = \{enabled = 1; \};' "$project_file"; then
    fail "the base Hourleaf target must remain local-only"
fi
if (( ${#model_files[@]} == 0 )); then
    fail "expected Hourleaf Core Data model files"
fi
[[ -f "$entitlements_file" ]] || fail "the Hourleaf app App Group entitlements are missing"
[[ -f "$extension_entitlements_file" ]] || fail "the Hourleaf Quick Surfaces App Group entitlements are missing"
if ! plutil -lint -s "$entitlements_file" >/dev/null 2>&1 \
    || ! plutil -lint -s "$extension_entitlements_file" >/dev/null 2>&1; then
    fail "the Hourleaf App Group entitlements are not valid property lists"
fi
if ! grep -Fq 'CODE_SIGN_ENTITLEMENTS = Hourleaf/Hourleaf.entitlements;' "$project_file" \
    || ! grep -Fq 'CODE_SIGN_ENTITLEMENTS = HourleafQuickSurfaces/HourleafQuickSurfaces.entitlements;' "$project_file"; then
    fail "the Hourleaf App Group entitlements are not configured for both targets"
fi

for model_file in "${model_files[@]}"; do
    if [[ "$(grep -Fc 'usedWithCloudKit="NO"' "$model_file")" != 1 ]] \
        || grep -Fq 'usedWithCloudKit="YES"' "$model_file"; then
        fail "expected a local-only Core Data model"
    fi
done

build_and_install() {
    if [[ "$test_mode" == "1" ]]; then
        print -r -- "skipped" > "$test_state_root/build-install-skipped"
        print "Fixture mode: build, install, and launch skipped."
        return 0
    fi

    xcodebuild \
        -project "$temporary_source/Hourleaf.xcodeproj" \
        -scheme Hourleaf \
        -configuration Debug \
        -destination "platform=iOS,id=$device_id" \
        -derivedDataPath "$derived_data" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$personal_team_id" \
        HOURLEAF_APP_BUNDLE_IDENTIFIER="$local_bundle_id" \
        HOURLEAF_QUICK_SURFACES_BUNDLE_IDENTIFIER="$local_extension_bundle_id" \
        HOURLEAF_APP_GROUP_IDENTIFIER="$local_app_group_id" \
        HOURLEAF_QUICK_ENTRY_URL_SCHEME="$local_quick_entry_url_scheme" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG HOURLEAF_LOCAL_DEVICE' \
        "${local_build_settings[@]}" \
        build

    app_path="$derived_data/Build/Products/Debug-iphoneos/Hourleaf.app"
    [[ -d "$app_path" ]] || fail "build did not produce the Hourleaf app"
    xcrun devicectl device install app --device "$device_id" "$app_path" \
        >"$device_command_log" 2>&1
    xcrun devicectl device process launch --device "$device_id" "$local_bundle_id" \
        >"$device_command_log" 2>&1
}

build_and_install

if (( is_smoke )); then
    print "Hourleaf Shortcut Smoke installation completed for $slice3_smoke_bundle_id."
else
    print "Hourleaf update completed for $standard_local_bundle_id."
fi
