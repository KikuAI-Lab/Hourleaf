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
        "$fixture_root/scripts" \
        "$fixture_root/Hourleaf/AppIntents" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV1.xcdatamodel" \
        "$fixture_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModelV2.xcdatamodel" \
        "$fixture_root/Hourleaf/UI/DataManagement"

    cp "$repo_root/Hourleaf/PrivacyInfo.xcprivacy" \
        "$fixture_root/Hourleaf/PrivacyInfo.xcprivacy"
    cp "$repo_root/Hourleaf.xcodeproj/project.pbxproj" \
        "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
    cp "$repo_root/scripts/install-local-device.sh" \
        "$fixture_root/scripts/install-local-device.sh"
    cp "$repo_root/Hourleaf/AppIntents/HourleafShortcuts.swift" \
        "$fixture_root/Hourleaf/AppIntents/HourleafShortcuts.swift"
    cp "$repo_root/Hourleaf/UI/DataManagement/DataManagementView.swift" \
        "$fixture_root/Hourleaf/UI/DataManagement/DataManagementView.swift"
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
replace_in_file \
    "$fixture_root/Hourleaf/PrivacyInfo.xcprivacy" \
    's#<false/>#<true/>#'
assert_failure_contains "privacy manifest enables tracking"

reset_fixture
print 'CODE_SIGN_ENTITLEMENTS = Hourleaf/Hourleaf.entitlements;' \
    >> "$fixture_root/Hourleaf.xcodeproj/project.pbxproj"
assert_failure_contains "code-sign entitlements are configured"

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
replace_in_file \
    "$fixture_root/scripts/install-local-device.sh" \
    's/slice3_smoke_bundle_id="com.kikuai.hourleaf.slice3smoke"/slice3_smoke_bundle_id="com.kikuai.hourleaf"/'
assert_failure_contains "bundle identifiers must be distinct"

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

print "Release readiness guard self-test passed."
