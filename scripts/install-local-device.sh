#!/bin/zsh

set -euo pipefail

if (( $# != 2 && $# != 3 )); then
    print -u2 "Usage: $0 <personal-team-id> <device-id> [--slice3-smoke]"
    exit 64
fi

if (( $# == 3 )) && [[ "$3" != "--slice3-smoke" ]]; then
    print -u2 "Usage: $0 <personal-team-id> <device-id> [--slice3-smoke]"
    exit 64
fi

personal_team_id="$1"
device_id="$2"
repo_root="${0:A:h:h}"
production_bundle_id="com.kikuai.hourleaf"
standard_local_bundle_id="com.kikuai.hourleaf.local"
slice3_smoke_bundle_id="com.kikuai.hourleaf.slice3smoke"
if [[ "$slice3_smoke_bundle_id" == "$production_bundle_id" || "$slice3_smoke_bundle_id" == "$standard_local_bundle_id" ]]; then
    print -u2 "Slice 3 smoke bundle identifier must differ from production and standard local builds."
    exit 65
fi

local_bundle_id="$standard_local_bundle_id"
typeset -a smoke_build_settings=()
if (( $# == 3 )); then
    local_bundle_id="$slice3_smoke_bundle_id"
    smoke_build_settings=("INFOPLIST_KEY_CFBundleDisplayName=Hourleaf Shortcut Smoke")
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/hourleaf-local.XXXXXX")"
temporary_source="$temporary_root/source"
derived_data="$temporary_root/derived-data"

cleanup() {
    if [[ -d "$temporary_root" && "${temporary_root:t}" == hourleaf-local.* ]]; then
        rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT

if [[ ! "$personal_team_id" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "Invalid Apple team identifier: expected 10 uppercase letters or digits."
    exit 64
fi

lock_state_file="$temporary_root/lock-state.json"
xcrun devicectl device info lockState \
    --device "$device_id" \
    --json-output "$lock_state_file" \
    --quiet
if [[ "$(plutil -extract result.passcodeRequired raw -o - "$lock_state_file")" != false ]]; then
    print -u2 "Unlock the iPhone and keep its screen on, then run the installer again."
    exit 69
fi

rsync -a --exclude .git --exclude .DS_Store "$repo_root/" "$temporary_source/"

project_file="$temporary_source/Hourleaf.xcodeproj/project.pbxproj"
entitlements_file="$temporary_source/Hourleaf/Hourleaf.entitlements"
typeset -a model_files
while IFS= read -r model_file; do
    model_files+=("$model_file")
done < <(find "$temporary_source" -type f -path '*.xcdatamodel/contents' -print | sort)

if grep -Eq 'com\.apple\.(iCloud|Push) = \{enabled = 1; \};' "$project_file"; then
    print -u2 "The base Hourleaf target must remain local-only."
    exit 65
fi
if (( ${#model_files[@]} == 0 )); then
    print -u2 "Expected Hourleaf Core Data model files."
    exit 65
fi
if [[ -e "$entitlements_file" ]] || grep -Fq 'CODE_SIGN_ENTITLEMENTS = Hourleaf/Hourleaf.entitlements;' "$project_file"; then
    print -u2 "The base Hourleaf target must not ship iCloud entitlements."
    exit 65
fi

for model_file in "${model_files[@]}"; do
    if [[ "$(grep -Fc 'usedWithCloudKit="NO"' "$model_file")" != 1 ]] || grep -Fq 'usedWithCloudKit="YES"' "$model_file"; then
        print -u2 "Expected a local-only Core Data model in $model_file."
        exit 65
    fi
done

xcodebuild \
    -project "$temporary_source/Hourleaf.xcodeproj" \
    -scheme Hourleaf \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$personal_team_id" \
    PRODUCT_BUNDLE_IDENTIFIER="$local_bundle_id" \
    CODE_SIGN_ENTITLEMENTS='' \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG HOURLEAF_LOCAL_DEVICE' \
    "${smoke_build_settings[@]}" \
    build

app_path="$derived_data/Build/Products/Debug-iphoneos/Hourleaf.app"
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" "$local_bundle_id"

if (( $# == 3 )); then
    print "Hourleaf Shortcut Smoke local-only build installed and launched."
else
    print "Hourleaf local-only build installed and launched."
fi
