#!/bin/zsh

set -euo pipefail

fail() {
    print -u2 -- "Release readiness guard self-test failed: $1"
    exit 1
}

script_path="${0:A}"
repo_root="${script_path:h:h}"
guard="$repo_root/scripts/verify-release-readiness.sh"
[[ -x "$guard" ]] || fail "guard is not executable"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/hourleaf-release-guard.XXXXXX")"
cleanup() {
    if [[ -d "$temporary_root" && "${temporary_root:t}" == hourleaf-release-guard.* ]]; then
        rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT

stdout_file="$temporary_root/stdout"
stderr_file="$temporary_root/stderr"
fixture_root="$temporary_root/fixture"

run_guard() {
    local root="${1:-}"
    : > "$stdout_file"
    : > "$stderr_file"
    if [[ -n "$root" ]]; then
        HOURLEAF_RELEASE_GUARD_TEST_ROOT="$root" "$guard" >"$stdout_file" 2>"$stderr_file"
    else
        HOURLEAF_RELEASE_GUARD_TEST_ROOT= "$guard" >"$stdout_file" 2>"$stderr_file"
    fi
}

replace_in_file() {
    local file="$1"
    local expression="$2"
    local rewritten="$file.rewritten"
    sed "$expression" "$file" >"$rewritten"
    mv -- "$rewritten" "$file"
}

copy_fixture() {
    mkdir -p \
        "$fixture_root/Hourleaf.xcodeproj" \
        "$fixture_root/Hourleaf" \
        "$fixture_root/HourleafQuickSurfaces" \
        "$fixture_root/HourleafShared" \
        "$fixture_root/HourleafWatch" \
        "$fixture_root/HourleafWatchShared" \
        "$fixture_root/AppStore/metadata/en-US" \
        "$fixture_root/AppStore/metadata/ru" \
        "$fixture_root/AppStore/metadata/uk" \
        "$fixture_root/AppStore/screenshots" \
        "$fixture_root/scripts" \
        "$fixture_root/Hourleaf/AppIntents" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel" \
        "$fixture_root/Hourleaf/UI/DataManagement"
    mkdir -p "$fixture_root/Hourleaf/UI"

    cp "$repo_root/Hourleaf/PrivacyInfo.xcprivacy" \
        "$fixture_root/Hourleaf/PrivacyInfo.xcprivacy"
    cp "$repo_root/Hourleaf.xcodeproj/project.pbxproj" \
        "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
    cp "$repo_root/Hourleaf/Hourleaf.entitlements" \
        "$fixture_root/Hourleaf/Hourleaf.entitlements"
    cp "$repo_root/Hourleaf/Info.plist" \
        "$fixture_root/Hourleaf/Info.plist"
    cp "$repo_root/HourleafQuickSurfaces/HourleafQuickSurfaces.entitlements" \
        "$fixture_root/HourleafQuickSurfaces/HourleafQuickSurfaces.entitlements"
    cp "$repo_root/HourleafQuickSurfaces/Info.plist" \
        "$fixture_root/HourleafQuickSurfaces/Info.plist"
    cp "$repo_root/HourleafQuickSurfaces/PrivacyInfo.xcprivacy" \
        "$fixture_root/HourleafQuickSurfaces/PrivacyInfo.xcprivacy"
    cp "$repo_root/HourleafQuickSurfaces/HourleafQuickSurfacesEntry.swift" \
        "$fixture_root/HourleafQuickSurfaces/HourleafQuickSurfacesEntry.swift"
    cp "$repo_root/AppStore/ExportOptions-AppStore.plist" \
        "$fixture_root/AppStore/ExportOptions-AppStore.plist"
    cp "$repo_root/HourleafShared/QuickSurfaceState.swift" \
        "$fixture_root/HourleafShared/QuickSurfaceState.swift"
    cp "$repo_root/HourleafWatch"/*.swift \
        "$fixture_root/HourleafWatch/"
    cp "$repo_root/HourleafWatch/PrivacyInfo.xcprivacy" \
        "$fixture_root/HourleafWatch/PrivacyInfo.xcprivacy"
    cp "$repo_root/HourleafWatchShared/WatchTimeEntryContract.swift" \
        "$fixture_root/HourleafWatchShared/WatchTimeEntryContract.swift"
    cp "$repo_root/scripts/install-local-device.sh" \
        "$fixture_root/scripts/install-local-device.sh"
    cp "$repo_root/Hourleaf/AppIntents/HourleafShortcuts.swift" \
        "$fixture_root/Hourleaf/AppIntents/HourleafShortcuts.swift"
    cp "$repo_root/Hourleaf/UI/DataManagement/DataManagementView.swift" \
        "$fixture_root/Hourleaf/UI/DataManagement/DataManagementView.swift"
    cp "$repo_root/Hourleaf/UI/SettingsScreen.swift" \
        "$fixture_root/Hourleaf/UI/SettingsScreen.swift"
    cp "$repo_root/AppStore/README.md" \
        "$repo_root/AppStore/privacy-details.md" \
        "$repo_root/AppStore/review-notes.md" \
        "$repo_root/AppStore/release-checklist.md" \
        "$repo_root/AppStore/age-rating.md" \
        "$repo_root/AppStore/accessibility.md" \
        "$fixture_root/AppStore/"
    for locale in en-US ru uk; do
        cp "$repo_root/AppStore/metadata/$locale"/*.txt \
            "$fixture_root/AppStore/metadata/$locale/"
    done
    cp -R "$repo_root/AppStore/screenshots/." \
        "$fixture_root/AppStore/screenshots/"
    cp "$repo_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel/contents" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel/contents"
    cp "$repo_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel/contents" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel/contents"
}

reset_fixture() {
    if [[ -d "$fixture_root" ]]; then
        rm -rf -- "$fixture_root"
    fi
    copy_fixture
}

assert_failure_contains() {
    local expected="$1"
    local exit_status
    if run_guard "$fixture_root"; then
        exit_status=0
    else
        exit_status=$?
    fi
    (( exit_status != 0 )) || fail "fixture drift unexpectedly passed: $expected"
    grep -Fq "$expected" "$stderr_file" \
        || fail "fixture drift did not report '$expected': $(<"$stderr_file")"
}

for forbidden_tool in xcodebuild xcrun codesign devicectl curl git; do
    if grep -Eq "(^|[[:space:];|])${forbidden_tool}([[:space:];|]|$)" "$guard"; then
        fail "guard references forbidden tool: $forbidden_tool"
    fi
done

if run_guard; then
    [[ "$(<"$stdout_file")" == "Release readiness guard passed." ]] \
        || fail "real-repository success receipt is not concise"
    [[ ! -s "$stderr_file" ]] || fail "real-repository guard wrote unexpected stderr"
else
    fail "real-repository guard failed: $(<"$stderr_file")"
fi

if "$guard" --self-test >"$stdout_file" 2>"$stderr_file"; then
    fail "guard accepted a caller-supplied argument"
fi
grep -Fq "accepts no arguments" "$stderr_file" \
    || fail "argument rejection did not report the interface contract"

reset_fixture
if run_guard "$fixture_root"; then
    [[ "$(<"$stdout_file")" == "Release readiness guard passed." ]] \
        || fail "valid fixture success receipt is not concise"
else
    fail "valid fixture failed: $(<"$stderr_file")"
fi

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf.xcodeproj/project.pbxproj" \
    's/GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Hourleaf\/Info.plist;/GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = Hourleaf\/Info.plist;/g'
assert_failure_contains "Hourleaf app target must use Hourleaf/Info.plist"

reset_fixture
print 'import CoreData' >> "$fixture_root/HourleafShared/QuickSurfaceState.swift"
assert_failure_contains "forbidden extension source dependency"

reset_fixture
print 'let backupReference = HourleafBackupV1.self' >> "$fixture_root/HourleafQuickSurfaces/HourleafQuickSurfacesEntry.swift"
assert_failure_contains "forbidden extension source dependency"

reset_fixture
print 'import CoreData' >> "$fixture_root/HourleafWatchShared/WatchTimeEntryContract.swift"
assert_failure_contains "forbidden Watch source dependency"

reset_fixture
replace_in_file \
    "$fixture_root/HourleafQuickSurfaces/Info.plist" \
    's#<string>\$(EXECUTABLE_NAME)</string>#<string></string>#'
assert_failure_contains "HourleafQuickSurfaces Info.plist has an empty CFBundleExecutable"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/Info.plist" \
    's#<string>\$(HOURLEAF_APP_GROUP_IDENTIFIER)</string>#<string>group.invalid.hourleaf</string>#'
assert_failure_contains "Hourleaf Info.plist HourleafAppGroupIdentifier is not the required build setting"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/Info.plist" \
    's#<string>com.kikuai.hourleaf.backup</string>#<string>com.invalid.hourleaf.backup</string>#'
assert_failure_contains "Hourleaf Info.plist UTExportedTypeDeclarations.0.UTTypeIdentifier is not the required build setting"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/Info.plist" \
    's#<string>hourleafbackup</string>#<string>invalidbackup</string>#'
assert_failure_contains "Hourleaf Info.plist backup filename extension drifted"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/Info.plist" \
    's#<string>\$(HOURLEAF_QUICK_ENTRY_URL_SCHEME)</string>#<string>hourleaf</string>#g'
assert_failure_contains "Hourleaf Info.plist HourleafQuickEntryURLScheme is not the required build setting"

reset_fixture
replace_in_file \
    "$fixture_root/HourleafQuickSurfaces/Info.plist" \
    's#<string>\$(HOURLEAF_QUICK_ENTRY_URL_SCHEME)</string>#<string>hourleaf</string>#'
assert_failure_contains "HourleafQuickSurfaces Info.plist HourleafQuickEntryURLScheme is not the required build setting"

reset_fixture
print 'let documentationLink = "https://developer.apple.com/documentation/foundation/urlsession"' \
    >> "$fixture_root/Hourleaf/AppIntents/HourleafShortcuts.swift"
if ! run_guard "$fixture_root"; then
    fail "plain developer URL link was treated as a runtime network reference: $(<"$stderr_file")"
fi

reset_fixture
print 'packageProductDependencies = (' \
    >> "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
print '    A10000000000000000000099,' \
    >> "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
print ');' \
    >> "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
assert_failure_contains "Swift package product dependency is configured"

reset_fixture
print 'import Network' \
    >> "$fixture_root/Hourleaf/AppIntents/HourleafShortcuts.swift"
assert_failure_contains "forbidden privacy-sensitive framework or SDK reference"

reset_fixture
print 'import Network' \
    >> "$fixture_root/HourleafQuickSurfaces/HourleafQuickSurfacesEntry.swift"
assert_failure_contains "forbidden privacy-sensitive framework or SDK reference"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/PrivacyInfo.xcprivacy" \
    's#<false/>#<true/>#'
assert_failure_contains "privacy manifest enables tracking"

reset_fixture
replace_in_file \
    "$fixture_root/HourleafQuickSurfaces/PrivacyInfo.xcprivacy" \
    's#<string>35F9.1</string>#<string>invalid</string>#'
assert_failure_contains "extension privacy manifest has an unexpected NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf.xcodeproj/project.pbxproj" \
    's/MARKETING_VERSION = 1.0.1;/MARKETING_VERSION = 0.9.0;/g'
assert_failure_contains "all shipping targets must use marketing version 1.0.1"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf.xcodeproj/project.pbxproj" \
    's/CURRENT_PROJECT_VERSION = 12;/CURRENT_PROJECT_VERSION = 11;/g'
assert_failure_contains "all shipping targets must use build number 12"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/UI/SettingsScreen.swift" \
    's/forInfoDictionaryKey: "CFBundleShortVersionString"/forInfoDictionaryKey: "CFBundleDisplayName"/'
assert_failure_contains "Settings must read the installed version from bundle metadata"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/Hourleaf.entitlements" \
    's/\$(HOURLEAF_APP_GROUP_IDENTIFIER)/group.invalid.hourleaf/'
assert_failure_contains "App Group entitlement is not parameterized"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel/contents" \
    's/usedWithCloudKit="NO"/usedWithCloudKit="YES"/'
assert_failure_contains "Core Data model is not local-only"

reset_fixture
print 'AppShortcut(intent: OpenQuickEntryIntent())' \
    >> "$fixture_root/Hourleaf/AppIntents/HourleafShortcuts.swift"
assert_failure_contains "expected exactly three AppShortcut declarations"

reset_fixture
print 'AppShortcut(intent: WatchRecordServiceTimeIntent())' \
    >> "$fixture_root/HourleafWatch/WatchRecordTimeIntent.swift"
assert_failure_contains "expected exactly two Watch AppShortcut declarations"

reset_fixture
replace_in_file \
    "$fixture_root/scripts/install-local-device.sh" \
    's/slice3_smoke_bundle_id="com.kikuai.hourleaf.slice3smoke"/slice3_smoke_bundle_id="com.kikuai.hourleaf"/'
assert_failure_contains "bundle identifiers must be distinct"

reset_fixture
replace_in_file \
    "$fixture_root/scripts/install-local-device.sh" \
    's/slice3_smoke_watch_bundle_id="com.kikuai.hourleaf.slice3smoke.watchkitapp"/slice3_smoke_watch_bundle_id="com.kikuai.hourleaf.watchkitapp"/'
assert_failure_contains "Watch identifiers must be distinct"

reset_fixture
replace_in_file \
    "$fixture_root/scripts/install-local-device.sh" \
    's/standard_local_watch_bundle_id="com.kikuai.hourleaf.local.watchkitapp"/standard_local_watch_bundle_id="com.kikuai.hourleaf.other.watchkitapp"/'
assert_failure_contains "each Watch identifier must belong to its companion iPhone app"

reset_fixture
replace_in_file \
    "$fixture_root/scripts/install-local-device.sh" \
    's/slice3_smoke_quick_entry_url_scheme="hourleaf-slice3smoke"/slice3_smoke_quick_entry_url_scheme="hourleaf"/'
assert_failure_contains "quick-entry URL schemes must be distinct"

reset_fixture
replace_in_file \
    "$fixture_root/scripts/install-local-device.sh" \
    '/--exclude build/d'
assert_failure_contains "local installer does not exclude generated build artifacts"

reset_fixture
replace_in_file \
    "$fixture_root/Hourleaf/UI/DataManagement/DataManagementView.swift" \
    '/^[[:space:]]*#if[[:space:]]+HOURLEAF_LOCAL_DEVICE[[:space:]]*$/d; /^[[:space:]]*#endif[[:space:]]*$/d'
assert_failure_contains "local migration guidance is not fully compile-time guarded"

reset_fixture
print 'This subtitle is deliberately longer than thirty characters' \
    > "$fixture_root/AppStore/metadata/en-US/subtitle.txt"
assert_failure_contains "en-US subtitle exceeds the 30-character App Store limit"

reset_fixture
rm "$fixture_root/AppStore/screenshots/uk/watch-46mm/01-direct-entry.png"
assert_failure_contains "App Store screenshot is missing"

print "Release readiness guard self-test passed."
