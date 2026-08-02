#!/bin/zsh

set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: $0 <personal-team-id> <device-id>"
    exit 64
fi

personal_team_id="$1"
device_id="$2"
repo_root="${0:A:h:h}"
local_bundle_id="com.kikuai.hourleaf.local"
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
model_file="$temporary_source/Hourleaf/Persistence/HourleafModel.xcdatamodeld/HourleafModel.xcdatamodel/contents"
entitlements_file="$temporary_source/Hourleaf/Hourleaf.entitlements"
if [[ "$(grep -Fc 'com.apple.iCloud = {enabled = 1; };' "$project_file")" != 1 ]]; then
    print -u2 "Expected exactly one enabled iCloud target capability."
    exit 65
fi
if [[ "$(grep -Fc 'usedWithCloudKit="YES"' "$model_file")" != 1 || ! -f "$entitlements_file" ]]; then
    print -u2 "Expected the production CloudKit model and entitlements file."
    exit 65
fi

perl -ni -e \
    'print unless /com\.apple\.(?:iCloud|Push) = \{enabled = 1; \};/' \
    "$project_file"
perl -0pi -e 's/usedWithCloudKit="YES"/usedWithCloudKit="NO"/' "$model_file"
rm -- "$entitlements_file"

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
    build

app_path="$derived_data/Build/Products/Debug-iphoneos/Hourleaf.app"
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" "$local_bundle_id"

print "Hourleaf local-only build installed and launched."
