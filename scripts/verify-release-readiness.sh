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
extension_manifest_file="$repo_root/HourleafQuickSurfaces/PrivacyInfo.xcprivacy"
watch_manifest_file="$repo_root/HourleafWatch/PrivacyInfo.xcprivacy"
project_file="$repo_root/Hourleaf.xcodeproj/project.pbxproj"
installer_file="$repo_root/scripts/install-local-device.sh"
models_root="$repo_root/Hourleaf/Persistence/HourleafModel.xcdatamodeld"
data_management_file="$repo_root/Hourleaf/UI/DataManagement/DataManagementView.swift"
extension_info_file="$repo_root/HourleafQuickSurfaces/Info.plist"
app_info_file="$repo_root/Hourleaf/Info.plist"
app_store_root="$repo_root/AppStore"
app_store_export_options="$app_store_root/ExportOptions-AppStore.plist"
app_store_screenshots_root="$app_store_root/screenshots"

for required_file in \
    "$manifest_file" \
    "$extension_manifest_file" \
    "$watch_manifest_file" \
    "$project_file" \
    "$installer_file" \
    "$data_management_file" \
    "$app_info_file" \
    "$extension_info_file" \
    "$app_store_export_options"; do
    [[ -f "$required_file" ]] || fail "required release surface is missing: ${required_file#$repo_root/}"
done
[[ -d "$models_root" ]] || fail "Core Data model bundle is missing"
[[ -d "$repo_root/HourleafWatch" ]] || fail "Hourleaf Watch source root is missing"
[[ -d "$repo_root/HourleafWatchShared" ]] || fail "Hourleaf Watch contract source root is missing"
for release_document in README.md privacy-details.md review-notes.md release-checklist.md age-rating.md accessibility.md; do
    [[ -f "$app_store_root/$release_document" ]] \
        || fail "App Store release document is missing: AppStore/$release_document"
done
[[ -f "$app_store_screenshots_root/README.md" ]] \
    || fail "App Store screenshot inventory is missing"

assert_screenshot_dimensions() {
    local file="$1"
    local expected_width="$2"
    local expected_height="$3"
    local width
    local height

    [[ -f "$file" ]] \
        || fail "App Store screenshot is missing: ${file#$repo_root/}"
    width="$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    height="$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] \
        || fail "App Store screenshot has unexpected dimensions: ${file#$repo_root/}"
}

for screenshot_locale in en-US ru uk; do
    for screenshot_name in 01-quick-entry.png 02-history-calendar.png 03-monthly-report.png; do
        assert_screenshot_dimensions \
            "$app_store_screenshots_root/$screenshot_locale/iphone-6.9/$screenshot_name" \
            1320 \
            2868
    done
    assert_screenshot_dimensions \
        "$app_store_screenshots_root/$screenshot_locale/watch-46mm/01-direct-entry.png" \
        416 \
        496
done

if ! plutil -lint -s "$extension_info_file" >/dev/null 2>&1; then
    fail "HourleafQuickSurfaces Info.plist is not a valid property list"
fi
if ! plutil -lint -s "$app_info_file" >/dev/null 2>&1; then
    fail "Hourleaf Info.plist is not a valid property list"
fi
if ! plutil -lint -s "$app_store_export_options" >/dev/null 2>&1; then
    fail "App Store export options are not a valid property list"
fi
[[ "$(plutil -extract method raw -o - "$app_store_export_options" 2>/dev/null)" == "app-store-connect" ]] \
    || fail "App Store export method drifted"
[[ "$(plutil -extract destination raw -o - "$app_store_export_options" 2>/dev/null)" == "upload" ]] \
    || fail "App Store export destination drifted"
[[ "$(plutil -extract signingStyle raw -o - "$app_store_export_options" 2>/dev/null)" == "automatic" ]] \
    || fail "App Store export signing style drifted"

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
assert_app_info_value ITSAppUsesNonExemptEncryption false
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
assert_extension_info_value ITSAppUsesNonExemptEncryption false
assert_extension_info_value NSExtension.NSExtensionPointIdentifier 'com.apple.widgetkit-extension'

assert_privacy_value() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local label="$4"
    local value
    if ! value="$(plutil -extract "$key" raw -o - "$file" 2>/dev/null)"; then
        fail "$label privacy manifest is missing $key"
    fi
    [[ "$value" == "$expected" ]] \
        || fail "$label privacy manifest has an unexpected $key"
}

assert_common_privacy_contract() {
    local file="$1"
    local label="$2"
    local tracking
    plutil -lint -s "$file" >/dev/null 2>&1 \
        || fail "$label privacy manifest is not a valid property list"
    tracking="$(plutil -extract NSPrivacyTracking raw -o - "$file" 2>/dev/null)" \
        || fail "$label privacy manifest is missing NSPrivacyTracking"
    [[ "$tracking" == "false" ]] || fail "$label privacy manifest enables tracking"
    for privacy_array_key in NSPrivacyCollectedDataTypes NSPrivacyTrackingDomains; do
        privacy_array="$(plutil -extract "$privacy_array_key" json -o - "$file" 2>/dev/null)" \
            || fail "$label privacy manifest is missing $privacy_array_key"
        [[ "$privacy_array" == "[]" ]] \
            || fail "$label privacy manifest declares $privacy_array_key"
    done
}

assert_common_privacy_contract "$manifest_file" "app"
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType NSPrivacyAccessedAPICategoryFileTimestamp app
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 3B52.1 app
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.1 C617.1 app
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType NSPrivacyAccessedAPICategorySystemBootTime app
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0 35F9.1 app
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPIType NSPrivacyAccessedAPICategoryUserDefaults app
assert_privacy_value "$manifest_file" NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPITypeReasons.0 CA92.1 app
if plutil -extract NSPrivacyAccessedAPITypes.3 raw -o - "$manifest_file" >/dev/null 2>&1; then
    fail "app privacy manifest declares an unexpected required-reason API category"
fi

assert_common_privacy_contract "$extension_manifest_file" "extension"
assert_privacy_value "$extension_manifest_file" NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType NSPrivacyAccessedAPICategoryFileTimestamp extension
assert_privacy_value "$extension_manifest_file" NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 C617.1 extension
assert_privacy_value "$extension_manifest_file" NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType NSPrivacyAccessedAPICategorySystemBootTime extension
assert_privacy_value "$extension_manifest_file" NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0 35F9.1 extension
if plutil -extract NSPrivacyAccessedAPITypes.2 raw -o - "$extension_manifest_file" >/dev/null 2>&1; then
    fail "extension privacy manifest declares an unexpected required-reason API category"
fi

assert_common_privacy_contract "$watch_manifest_file" "Watch app"
watch_accessed_api_types="$(plutil -extract NSPrivacyAccessedAPITypes json -o - "$watch_manifest_file" 2>/dev/null)" \
    || fail "Watch app privacy manifest is missing NSPrivacyAccessedAPITypes"
[[ "$watch_accessed_api_types" == "[]" ]] \
    || fail "Watch app privacy manifest declares a required-reason API category"

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
[[ "$target_count" == "5" ]] || fail "expected exactly five Xcode targets; found $target_count"
grep -Fq 'name = HourleafQuickSurfaces;' "$project_file" \
    || fail "HourleafQuickSurfaces target is missing"
grep -Fq 'name = HourleafWatch;' "$project_file" \
    || fail "HourleafWatch target is missing"
grep -Fq 'name = "Embed Watch Content";' "$project_file" \
    || fail "Hourleaf app does not embed Watch content"
grep -Fq 'dstSubfolderSpec = 16;' "$project_file" \
    || fail "Hourleaf Watch app is not embedded in the Watch destination"

app_info_config_count="$(grep -F 'GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Hourleaf/Info.plist;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$app_info_config_count" == "2" ]] \
    || fail "Hourleaf app target must use Hourleaf/Info.plist with generated Info disabled in both configurations"
extension_info_config_count="$(grep -F 'GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = HourleafQuickSurfaces/Info.plist;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$extension_info_config_count" == "2" ]] \
    || fail "HourleafQuickSurfaces target must use HourleafQuickSurfaces/Info.plist with generated Info disabled in both configurations"
watch_companion_config_count="$(grep -F 'INFOPLIST_KEY_WKCompanionAppBundleIdentifier = "$(HOURLEAF_APP_BUNDLE_IDENTIFIER)";' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$watch_companion_config_count" == "2" ]] \
    || fail "HourleafWatch must link to the parameterized iPhone app in both configurations"
watch_bundle_config_count="$(grep -F 'PRODUCT_BUNDLE_IDENTIFIER = "$(HOURLEAF_WATCH_BUNDLE_IDENTIFIER)";' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$watch_bundle_config_count" == "2" ]] \
    || fail "HourleafWatch must use the parameterized Watch bundle identifier in both configurations"
watch_deployment_count="$(grep -F 'WATCHOS_DEPLOYMENT_TARGET = 10.0;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$watch_deployment_count" == "2" ]] \
    || fail "HourleafWatch must support watchOS 10 or later in both configurations"
release_version_count="$(grep -Fo 'MARKETING_VERSION = 1.0.0;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$release_version_count" == "6" ]] \
    || fail "all shipping targets must use marketing version 1.0.0"
watch_encryption_count="$(grep -F 'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;' "$project_file" | wc -l | tr -d '[:space:]' || true)"
[[ "$watch_encryption_count" == "2" ]] \
    || fail "HourleafWatch export-compliance declaration is missing"

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
    "$repo_root/HourleafQuickSurfaces"/**/*.swift(N) \
    "$repo_root/HourleafWatch"/**/*.swift(N) \
    "$repo_root/HourleafWatchShared"/**/*.swift(N); do
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

for watch_source_root in "$repo_root/HourleafWatch" "$repo_root/HourleafWatchShared"; do
    while IFS= read -r source_file; do
        forbidden_watch_reference="$(awk -v pattern='(^|[^[:alnum:]_])[[:alnum:]_]*(CoreData|NSPersistent|LedgerRepository|HourleafBackup|RawBackup|BackupCodec|BackupExporter|CSV|URLSession|NWConnection|Network|Analytics|Telemetry|Tracking)[[:alnum:]_]*([^[:alnum:]_]|$)' '
            {
                line = $0
                gsub(/https?:\/\/[^[:space:]\"]+/, "", line)
                if (line ~ pattern) print FNR ":" $0
            }
        ' "$source_file")"
        [[ -z "$forbidden_watch_reference" ]] \
            || fail "forbidden Watch source dependency in ${source_file#$repo_root/}"
    done < <(find "$watch_source_root" -type f -name '*.swift' -print | sort)
done

shortcut_count="$(find "$repo_root/Hourleaf" -type f -name '*.swift' -exec grep -Eho 'AppShortcut[[:space:]]*\(' {} + 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
[[ "$shortcut_count" == "3" ]] || fail "expected exactly three AppShortcut declarations; found $shortcut_count"
watch_shortcut_count="$(find "$repo_root/HourleafWatch" -type f -name '*.swift' -exec grep -Eho 'AppShortcut[[:space:]]*\(' {} + 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
[[ "$watch_shortcut_count" == "2" ]] || fail "expected exactly two Watch AppShortcut declarations; found $watch_shortcut_count"

production_bundle_id="$(sed -n 's/^[[:space:]]*production_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_extension_bundle_id="$(sed -n 's/^[[:space:]]*production_extension_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_watch_bundle_id="$(sed -n 's/^[[:space:]]*production_watch_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_app_group_id="$(sed -n 's/^[[:space:]]*production_app_group_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
production_quick_entry_url_scheme="$(sed -n 's/^[[:space:]]*production_quick_entry_url_scheme="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_bundle_id="$(sed -n 's/^[[:space:]]*standard_local_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_extension_bundle_id="$(sed -n 's/^[[:space:]]*standard_local_extension_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_watch_bundle_id="$(sed -n 's/^[[:space:]]*standard_local_watch_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_app_group_id="$(sed -n 's/^[[:space:]]*standard_local_app_group_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_quick_entry_url_scheme="$(sed -n 's/^[[:space:]]*standard_local_quick_entry_url_scheme="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_bundle_id="$(sed -n 's/^[[:space:]]*slice3_smoke_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_extension_bundle_id="$(sed -n 's/^[[:space:]]*slice3_smoke_extension_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_watch_bundle_id="$(sed -n 's/^[[:space:]]*slice3_smoke_watch_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_app_group_id="$(sed -n 's/^[[:space:]]*slice3_smoke_app_group_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_quick_entry_url_scheme="$(sed -n 's/^[[:space:]]*slice3_smoke_quick_entry_url_scheme="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"

[[ "$production_bundle_id" == "com.kikuai.hourleaf" ]] || fail "production bundle identifier drifted"
[[ "$production_extension_bundle_id" == "com.kikuai.hourleaf.quick-surfaces" ]] \
    || fail "production extension bundle identifier drifted"
[[ "$production_watch_bundle_id" == "com.kikuai.hourleaf.watchkitapp" ]] \
    || fail "production Watch bundle identifier drifted"
[[ "$production_app_group_id" == "group.com.kikuai.hourleaf" ]] \
    || fail "production App Group identifier drifted"
[[ "$production_quick_entry_url_scheme" == "hourleaf" ]] \
    || fail "production quick-entry URL scheme drifted"
[[ -n "$standard_local_bundle_id" && -n "$standard_local_extension_bundle_id" && -n "$standard_local_watch_bundle_id" && -n "$standard_local_app_group_id" \
    && -n "$standard_local_quick_entry_url_scheme" && -n "$smoke_bundle_id" \
    && -n "$smoke_extension_bundle_id" && -n "$smoke_watch_bundle_id" && -n "$smoke_app_group_id" \
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
if [[ "$production_watch_bundle_id" == "$standard_local_watch_bundle_id" \
    || "$production_watch_bundle_id" == "$smoke_watch_bundle_id" \
    || "$standard_local_watch_bundle_id" == "$smoke_watch_bundle_id" ]]; then
    fail "production, normal local, and disposable smoke Watch identifiers must be distinct"
fi
if [[ "$production_watch_bundle_id" != "$production_bundle_id.watchkitapp" \
    || "$standard_local_watch_bundle_id" != "$standard_local_bundle_id.watchkitapp" \
    || "$smoke_watch_bundle_id" != "$smoke_bundle_id.watchkitapp" ]]; then
    fail "each Watch identifier must belong to its companion iPhone app"
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
grep -Fq 'HOURLEAF_WATCH_BUNDLE_IDENTIFIER = com.kikuai.hourleaf.watchkitapp;' "$project_file" \
    || fail "production Watch bundle identifier is missing from the Xcode project"
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

check_metadata_limit() {
    local file="$1"
    local limit="$2"
    local label="$3"
    local value
    local count
    [[ -f "$file" ]] || fail "App Store metadata is missing: ${file#$repo_root/}"
    value="$(<"$file")"
    [[ -n "$value" ]] || fail "$label is empty"
    count="${#value}"
    (( count <= limit )) || fail "$label exceeds the $limit-character App Store limit"
}

for locale in en-US ru uk; do
    metadata_root="$app_store_root/metadata/$locale"
    check_metadata_limit "$metadata_root/name.txt" 30 "$locale app name"
    check_metadata_limit "$metadata_root/subtitle.txt" 30 "$locale subtitle"
    check_metadata_limit "$metadata_root/promotional_text.txt" 170 "$locale promotional text"
    check_metadata_limit "$metadata_root/description.txt" 4000 "$locale description"
    check_metadata_limit "$metadata_root/keywords.txt" 100 "$locale keywords"
    check_metadata_limit "$metadata_root/release_notes.txt" 4000 "$locale release notes"
    [[ "$(<"$metadata_root/name.txt")" == "Hourleaf: Ministry Hours" ]] \
        || fail "$locale App Store name drifted"
done

print "Release readiness guard passed."
