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

for required_file in \
    "$manifest_file" \
    "$project_file" \
    "$installer_file" \
    "$data_management_file"; do
    [[ -f "$required_file" ]] || fail "required release surface is missing: ${required_file#$repo_root/}"
done
[[ -d "$models_root" ]] || fail "Core Data model bundle is missing"

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

entitlement_file="$(find "$repo_root" -path "$repo_root/.git" -prune -o -type f -name '*.entitlements' -print -quit 2>/dev/null || true)"
[[ -z "$entitlement_file" ]] || fail "entitlement file exists: ${entitlement_file#$repo_root/}"

configured_entitlements="$(find "$repo_root" -path "$repo_root/.git" -prune -o -type f \( -name '*.pbxproj' -o -name '*.xcconfig' \) -exec grep -Hn 'CODE_SIGN_ENTITLEMENTS' {} + 2>/dev/null || true)"
[[ -z "$configured_entitlements" ]] || fail "code-sign entitlements are configured"

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
    "$repo_root/Hourleaf"/**/*.swift(N); do
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

shortcut_count="$(find "$repo_root/Hourleaf" -type f -name '*.swift' -exec grep -Eho 'AppShortcut[[:space:]]*\(' {} + 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
[[ "$shortcut_count" == "3" ]] || fail "expected exactly three AppShortcut declarations; found $shortcut_count"

production_bundle_id="$(sed -n 's/^[[:space:]]*production_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
standard_local_bundle_id="$(sed -n 's/^[[:space:]]*standard_local_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"
smoke_bundle_id="$(sed -n 's/^[[:space:]]*slice3_smoke_bundle_id="\([^"]*\)".*/\1/p' "$installer_file" | head -n 1)"

[[ "$production_bundle_id" == "com.kikuai.hourleaf" ]] || fail "production bundle identifier drifted"
[[ -n "$standard_local_bundle_id" && -n "$smoke_bundle_id" ]] || fail "local bundle identifiers are missing"
if [[ "$production_bundle_id" == "$standard_local_bundle_id" \
    || "$production_bundle_id" == "$smoke_bundle_id" \
    || "$standard_local_bundle_id" == "$smoke_bundle_id" ]]; then
    fail "production, normal local, and disposable smoke bundle identifiers must be distinct"
fi
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.kikuai.hourleaf;' "$project_file" \
    || fail "production bundle identifier is missing from the Xcode project"

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
