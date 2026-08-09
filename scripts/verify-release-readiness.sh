#!/bin/zsh

set -euo pipefail

fail() {
    print -u2 -- "Release readiness guard failed: $1"
    exit 1
}

if (( $# != 0 )); then
    fail "this verifier accepts no arguments"
fi

script_path="${0:A}"
repo_root="${script_path:h:h}"

# This seam is intentionally test-only. Normal invocations always resolve the
# checkout containing this script and never accept a caller-supplied path.
if [[ -n "${HOURLEAF_RELEASE_GUARD_TEST_ROOT:-}" ]]; then
    test_root="${HOURLEAF_RELEASE_GUARD_TEST_ROOT}"
    [[ -d "$test_root" ]] || fail "test root does not exist"
    repo_root="${test_root:A}"
fi

manifest_file="$repo_root/Hourleaf/PrivacyInfo.xcprivacy"
project_file="$repo_root/Hourleaf.xcodeproj/project.pbxproj"
installer_file="$repo_root/scripts/install-local-device.sh"
models_root="$repo_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld"
data_management_file="$repo_root/Hourleaf/UI/DataManagement/DataManagementView.swift"
extension_info_file="$repo_root/HourleafQuickSurfaces/Info.plist"
app_info_file="$repo_root/Hourleaf/Info.plist"

for required_file in \
    "$manifest_file" \
    "$project_file" \
    "$installer_file" \
    "$data_management_file" \
    "$app_info_file" \
    "$extension_info_file"; do
    [[ -f "$required_file" ]] || fail "required release surface is missing: ${required_file#$repo_root/}"
done
[[ -d "$models_root" ]] || fail "Core Data model bundle is missing"

if ! plutil -lint -s "$extension_info_file" >/dev/null 2>&1; then
    fail "HourleafQuickSurfaces Info.plist is not a valid property list"
fi
if ! plutil -lint -s "$app_info_file" >/dev/null 2>&1; then
    fail "Hourleaf Info.plist is not a valid property list"
fi

assert_app_info_value() {
    local key="$1"
    local expected="$2"
    local value
    if ! value="$(plutil -extract "$key" raw -o - "$app_info_file" 2>/dev/null)"; then
        fail "Hourleaf Info.plist is missing $key"
    fi
    [[ -n "$value" ]] || fail "Hourleaf Info.plist has an empty $key"
    [[ "$value" == "$expected" ]] \
        || fail "Hourleaf Info.plist $key is not the required build setting"
}

assert_app_info_value CFBundleExecutable '$(EXECUTABLE_NAME)'
assert_app_info_value CFBundleIdentifier '$(PRODUCT_BUNDLE_IDENTIFIER)'
assert_app_info_value CFBundleName '$(PRODUCT_NAME)'
assert_app_info_value CFBundlePackageType 'APPL'
assert_app_info_value CFBundleShortVersionString '$(MARKETING_VERSION)'
assert_app_info_value CFBundleVersion '$(CURRENT_PROJECT_VERSION)'
assert_app_info_value HourleafAppGroupIdentifier '$(HOURLEAF_APP_GROUP_IDENTIFIER)'
assert_app_info_value HourleafQuickEntryURLScheme '$(HOURLEAF_QUICK_ENTRY_URL_SCHEME)'
assert_app_info_value CFBundleURLTypes.0.CFBundleURLSchemes.0 '$(HOURLEAF_QUICK_ENTRY_URL_SCHEME)'
assert_app_info_value LSApplicationCategoryType 'public.app-category.productivity'
assert_app_info_value UIApplicationSupportsIndirectInputEvents 'true'

if ! plutil -extract UIApplicationSceneManifest json -o - "$app_info_file" >/dev/null 2>&1; then
    fail "Hourleaf Info.plist is missing UIApplicationSceneManifest"
fi
if ! plutil -extract UILaunchScreen json -o - "$app_info_file" >/dev/null 2>&1; then
    fail "Hourleaf Info.plist is missing UILaunchScreen"
fi

assert_extension_info_value() {
    local key="$1"
    local expected="$2"
    local value
    if ! value="$(plutil -extract "$key" raw -o - "$extension_info_file" 2>/dev/null)"; then
        fail "HourleafQuickSurfaces Info.plist is missing $key"
    fi
    [[ -n "$value" ]] || fail "HourleafQuickSurfaces Info.plist has an empty $key"
    [[ "$value" == "$expected" ]] \
        || fail "HourleafQuickSurfaces Info.plist $key is not the required build setting"
}

assert_extension_info_value CFBundleExecutable '$(EXECUTABLE_NAME)'
assert_extension_info_value CFBundleIdentifier '$(PRODUCT_BUNDLE_IDENTIFIER)'
assert_extension_info_value CFBundleName '$(PRODUCT_NAME)'
assert_extension_info_value CFBundlePackageType 'XPC!'
assert_extension_info_value CFBundleShortVersionString '$(MARKETING_VERSION)'
assert_extension_info_value CFBundleVersion '$(CURRENT_PROJECT_VERSION)'
assert_extension_info_value HourleafAppGroupIdentifier '$(HOURLEAF_APP_GROUP_IDENTIFIER)'
assert_extension_info_value HourleafQuickEntryURLScheme '$(HOURLEAF_QUICK_ENTRY_URL_SCHEME)'
assert_extension_info_value NSExtension.NSExtensionPointIdentifier 'com.apple.widgetkit-extension'

if ! plutil -lint -s "$manifest_file" >/dev/null 2>&1; then
    fail "privacy manifest is not a valid property list"
fi

if ! privacy_tracking="$(plutil -extract NSPrivacyTracking raw -o - "$manifest_file" 2>/dev/null)"; then
    fail "privacy manifest is missing NSPrivacyTracking"
fi
[[ "$privacy_tracking" == "false" ]] || fail "privacy manifest enables tracking"

for privacy_array_key in \
    NSPrivacyCollectedDataTypes \
    NSPrivacyTrackingDomains \
    NSPrivacyAccessedAPITypes; do
    if ! privacy_array="$(plutil -extract "$privacy_array_key" json -o - "$manifest_file" 2>/dev/null)"; then
        fail "privacy manifest is missing $privacy_array_key"
    fi
    [[ "$privacy_array" == "[]" ]] || fail "privacy manifest declares $privacy_array_key"
done

app_entitlements_file="$repo_root/Hourleaf/Hourleaf.entitlements"
extension_entitlements_file="$repo_root/HourleafQuickSurfaces/HourleafQuickSurfaces.entitlements"
for entitlement_file in "$app_entitlements_file" "$extension_entitlements_file"; do
    [[ -f "$entitlement_file" ]] || fail "required App Group entitlement is missing: ${entitlement_file#$repo_root/}"
    plutil -lint -s "$entitlement_file" >/dev/null 2>&1 \
        || fail "App Group entitlement is not a valid property list: ${entitlement_file#$repo_root/}"
    app_group_value="$(plutil -p "$entitlement_file" 2>/dev/null | sed -n 's/^[[:space:]]*0 => "\(.*\)"$/\1/p' | head -n 1)"
    [[ "$app_group_value" == '$(HOURLEAF_APP_GROUP_IDENTIFIER)' ]] \
        || fail "App Group entitlement is not parameterized: ${entitlement_file#$repo_root/}"
done

grep -Fq 'CODE_SIGN_ENTITLEMENTS = Hourleaf/Hourleaf.entitlements;' "$project_file" \
    || fail "the Hourleaf app App Group entitlement is not configured"
grep -Fq 'CODE_SIGN_ENTITLEMENTS = HourleafQuickSurfaces/HourleafQuickSurfaces.entitlements;' "$project_file" \
    || fail "the Hourleaf Quick Surfaces App Group entitlement is not configured"

target_count="$(grep -E '^[[:space:]]*targets = \(' "$project_file" | head -n 1 | grep -Eo 'A[[:xdigit:]]{23}' | wc -l | tr -d '[:space:]')"
[[ "$target_count" == "4" ]] || fail "expected exactly four Xcode targets; found $target_count"
grep -Fq 'name = HourleafQuickSurfaces;' "$project_file" \
    || fail "HourleafQuickSurfaces target is missing"

app_info_config_count="$(grep -F 'GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Hourleaf/Info.plist;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$app_info_config_count" == "2" ]] \
    || fail "Hourleaf app target must use Hourleaf/Info.plist with generated Info disabled in both configurations"
extension_info_config_count="$(grep -F 'GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = HourleafQuickSurfaces/Info.plist;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$extension_info_config_count" == "2" ]] \
    || fail "HourleafQuickSurfaces target must use HourleafQuickSurfaces/Info.plist with generated Info disabled in both configurations"

typeset -a model_files=()
while IFS= read -r model_file; do
    model_files+=("$model_file")
done < <(find "$models_root" -type f -path '*.xcdatamodel/contents' -print | sort)
(( ${#model_files[@]} > 0 )) || fail "no Core Data model versions were found"

for model_file in "${model_files[@]}"; do
    cloudkit_no_count="$(grep -Fc 'usedWithCloudKit="NO"' "$model_file" 2>/dev/null || true)"
    cloudkit_yes_count="$(grep -Fc 'usedWithCloudKit="YES"' "$model_file" 2>/dev/null || true)"
    if [[ "$cloudkit_no_count" != "1" || "$cloudkit_yes_count" != "0" ]]; then
        fail "Core Data model is not local-only: ${model_file#$repo_root/}"
    fi
done

package_file="$(find "$repo_root" -path "$repo_root/.git" -prune -o -type f \( -name 'Package.swift' -o -name 'Package.resolved' \) -print -quit 2>/dev/null || true)"
[[ -z "$package_file" ]] || fail "Swift package dependency surface exists: ${package_file#$repo_root/}"

if awk '
    /packageProductDependencies[[:space:]]*=[[:space:]]*\(/ {
        remainder = $0
        sub(/^.*packageProductDependencies[[:space:]]*=[[:space:]]*\(/, "", remainder)
        if (remainder !~ /^[[:space:]]*\);/) found = 1
        in_list = (remainder !~ /\);/)
        next
    }
    in_list {
        if ($0 ~ /^[[:space:]]*\);/) {
            in_list = 0
            next
        }
        if ($0 !~ /^[[:space:]]*$/) found = 1
    }
    END { exit found ? 0 : 1 }
' "$project_file"; then
    fail "Swift package product dependency is configured"
fi
if grep -Eq 'PBXSwiftPackageProductDependency|XCRemoteSwiftPackageReference' "$project_file" 2>/dev/null; then
    fail "Swift package dependency reference is configured"
fi

for source_file in \
    "$repo_root/Hourleaf.xcodeproj/project.pbxproj" \
    "$repo_root/Hourleaf"/**/*.swift(N) \
    "$repo_root/HourleafShared"/**/*.swift(N) \
    "$repo_root/HourleafQuickSurfaces"/**/*.swift(N); do
    [[ -f "$source_file" ]] || continue
    forbidden_reference="$(awk -v pattern='(^|[^[:alnum:]_])(AdSupport|AppTrackingTransparency|iAd|GoogleMobileAds|GAD|Firebase|Mixpanel|Amplitude|Telemetry|Analytics|Sentry|Contacts|CoreLocation|LocationManager|CLLocation|AVFoundation|AVCapture|Photos|PhotosUI|PhotoKit|PhotoLibrary|HealthKit|HKHealthStore|UserTracking|NSCameraUsageDescription|NSMicrophoneUsageDescription|NSLocationUsageDescription|NSPhotoLibraryUsageDescription|URLSession|NWConnection|Network|WebKit|WKWebView)([^[:alnum:]_]|$)' '
        {
            line = $0
            gsub(/https?:\/\/[^[:space:]\"]+/, "", line)
            if (line ~ pattern) print FNR ":" $0
        }
    ' "$source_file")"
    [[ -z "$forbidden_reference" ]] || fail "forbidden privacy-sensitive framework or SDK reference in ${source_file#$repo_root/}"
done

for extension_source_root in "$repo_root/HourleafShared" "$repo_root/HourleafQuickSurfaces"; do
    [[ -d "$extension_source_root" ]] \
        || fail "extension source root is missing: ${extension_source_root#$repo_root/}"
    while IFS= read -r source_file; do
        forbidden_extension_reference="$(awk -v pattern='(^|[^[:alnum:]_])[[:alnum:]_]*(CoreData|NSPersistent|LedgerRepository|HourleafBackup|RawBackup|BackupCodec|BackupExporter|CSV|URLSession|NWConnection|Network)[[:alnum:]_]*([^[:alnum:]_]|$)' '
            {
                line = $0
                gsub(/https?:\/\/[^[:space:]\"]+/, "", line)
                if (line ~ pattern) print FNR ":" $0
            }
        ' "$source_file")"
        [[ -z "$forbidden_extension_reference" ]] \
            || fail "forbidden extension source dependency in ${source_file#$repo_root/}"
    done < <(find "$extension_source_root" -type f -name '*.swift' -print | sort)
done

shortcut_count="$(find "$repo_root/Hourleaf" -type f -name '*.swift' -exec grep -Eho 'AppShortcut[[:space:]]*\(' {} + 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
[[ "$shortcut_count" == "3" ]] || fail "expected exactly three AppShortcut declarations; found $shortcut_count"

production_bundle_id="$(sed -n 's/^[[:space:]]*production_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_extension_bundle_id="$(sed -n 's/^[[:space:]]*production_extension_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_app_group_id="$(sed -n 's/^[[:space:]]*production_app_group_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_quick_entry_url_scheme="$(sed -n 's/^[[:space:]]*production_quick_entry_url_scheme="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_bundle_id="$(sed -n 's/^[[:space:]]*standard_local_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_extension_bundle_id="$(sed -n 's/^[[:space:]]*standard_local_extension_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_app_group_id="$(sed -n 's/^[[:space:]]*standard_local_app_group_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_quick_entry_url_scheme="$(sed -n 's/^[[:space:]]*standard_local_quick_entry_url_scheme="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_bundle_id="$(sed -n 's/^[[:space:]]*slice3_smoke_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_extension_bundle_id="$(sed -n 's/^[[:space:]]*slice3_smoke_extension_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_app_group_id="$(sed -n 's/^[[:space:]]*slice3_smoke_app_group_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_quick_entry_url_scheme="$(sed -n 's/^[[:space:]]*slice3_smoke_quick_entry_url_scheme="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"

[[ "$production_bundle_id" == "com.kikuai.hourleaf" ]] || fail "production bundle identifier drifted"
[[ "$production_extension_bundle_id" == "com.kikuai.hourleaf.quick-surfaces" ]] \
    || fail "production extension bundle identifier drifted"
[[ "$production_app_group_id" == "group.com.kikuai.hourleaf" ]] \
    || fail "production App Group identifier drifted"
[[ "$production_quick_entry_url_scheme" == "hourleaf" ]] \
    || fail "production quick-entry URL scheme drifted"
[[ -n "$standard_local_bundle_id" && -n "$standard_local_extension_bundle_id" && -n "$standard_local_app_group_id" \
    && -n "$standard_local_quick_entry_url_scheme" && -n "$smoke_bundle_id" \
    && -n "$smoke_extension_bundle_id" && -n "$smoke_app_group_id" \
    && -n "$smoke_quick_entry_url_scheme" ]] \
    || fail "local app, extension, App Group, or quick-entry URL scheme identifiers are missing"
if [[ "$production_bundle_id" == "$standard_local_bundle_id" \
    || "$production_bundle_id" == "$smoke_bundle_id" \
    || "$standard_local_bundle_id" == "$smoke_bundle_id" ]]; then
    fail "production, normal local, and disposable smoke bundle identifiers must be distinct"
fi
if [[ "$production_extension_bundle_id" == "$standard_local_extension_bundle_id" \
    || "$production_extension_bundle_id" == "$smoke_extension_bundle_id" \
    || "$standard_local_extension_bundle_id" == "$smoke_extension_bundle_id" ]]; then
    fail "production, normal local, and disposable smoke extension identifiers must be distinct"
fi
if [[ "$production_app_group_id" == "$standard_local_app_group_id" \
    || "$production_app_group_id" == "$smoke_app_group_id" \
    || "$standard_local_app_group_id" == "$smoke_app_group_id" ]]; then
    fail "production, normal local, and disposable smoke App Group identifiers must be distinct"
fi
if [[ "$production_quick_entry_url_scheme" == "$standard_local_quick_entry_url_scheme" \
    || "$production_quick_entry_url_scheme" == "$smoke_quick_entry_url_scheme" \
    || "$standard_local_quick_entry_url_scheme" == "$smoke_quick_entry_url_scheme" ]]; then
    fail "production, normal local, and disposable smoke quick-entry URL schemes must be distinct"
fi
grep -Fq -- '--exclude build' "$installer_file" \
    || fail "local installer does not exclude generated build artifacts"
grep -Fq 'HOURLEAF_APP_BUNDLE_IDENTIFIER = com.kikuai.hourleaf;' "$project_file" \
    || fail "production bundle identifier is missing from the Xcode project"
grep -Fq 'HOURLEAF_QUICK_SURFACES_BUNDLE_IDENTIFIER = com.kikuai.hourleaf.quick-surfaces;' "$project_file" \
    || fail "production extension bundle identifier is missing from the Xcode project"
grep -Fq 'HOURLEAF_APP_GROUP_IDENTIFIER = group.com.kikuai.hourleaf;' "$project_file" \
    || fail "production App Group identifier is missing from the Xcode project"
grep -Fq 'HOURLEAF_QUICK_ENTRY_URL_SCHEME = hourleaf;' "$project_file" \
    || fail "production quick-entry URL scheme is missing from the Xcode project"

if ! awk '
    BEGIN { depth = 0; found = 0; unguarded = 0 }
    /^[[:space:]]*#if[[:space:]]+/ {
        depth++
        if ($0 ~ /^[[:space:]]*#if[[:space:]]+HOURLEAF_LOCAL_DEVICE([[:space:]]|$)/) {
            local_guard[depth] = 1
        }
        next
    }
    /^[[:space:]]*#endif([[:space:]]|$)/ {
        delete local_guard[depth]
        if (depth > 0) depth--
        next
    }
    /localBuildMigrationGuidance/ {
        found = 1
        guarded = 0
        for (level = 1; level <= depth; level++) {
            if (local_guard[level]) guarded = 1
        }
        if (!guarded) unguarded = 1
    }
    END { exit !(found && !unguarded && depth == 0) }
' "$data_management_file"; then
    fail "local migration guidance is not fully compile-time guarded"
fi

print "Release readiness guard passed."
