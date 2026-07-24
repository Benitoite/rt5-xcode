#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

log()
{
    printf '\n\033[1mRawTherapee Distribution: %s\033[0m\n' "$*"
}

die()
{
    printf 'RawTherapee Distribution error: %s\n' "$*" >&2
    exit 1
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' was not found."
}

project_directory="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
support_directory="${project_directory}/XcodeSupport"
source_directory="${project_directory}/RawTherapee5/rawtherapee"
configured_team_identifier="${RAWTHERAPEE_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
bundle_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-com.rawtherapee.rawtherapee5}"
notary_profile="${RAWTHERAPEE_NOTARY_PROFILE:-RawTherapee5}"
output_directory="${RAWTHERAPEE_DISTRIBUTION_OUTPUT_DIR:-${project_directory}/dist}"
products_directory="${BUILT_PRODUCTS_DIR:-${TARGET_BUILD_DIR:-}}"

[[ -n "$products_directory" ]] ||
    die "BUILT_PRODUCTS_DIR or TARGET_BUILD_DIR is required."

application="${products_directory}/RawTherapee.app"
[[ -d "$application" ]] ||
    die "The signed application was not found at ${application}."

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

require_command codesign
require_command create-dmg
require_command ditto
require_command magick
require_command xcrun

signature_details="$(/usr/bin/codesign -d --verbose=4 "$application" 2>&1)"
signing_authority="$(
    printf '%s\n' "$signature_details" |
        /usr/bin/awk -F= \
            '/^Authority=Developer ID Application:/ {
                sub(/^Authority=/, "")
                print
                exit
            }'
)"
[[ -n "$signing_authority" ]] ||
    die "The application is not signed with a Developer ID Application identity."

team_identifier="$(
    printf '%s\n' "$signature_details" |
        /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2; exit }'
)"
[[ -n "$team_identifier" && "$team_identifier" != "not set" ]] ||
    die "The application signature does not contain a TeamIdentifier."
if [[ -n "$configured_team_identifier" &&
      "$team_identifier" != "$configured_team_identifier" ]]; then
    die "The application was signed by team ${team_identifier}, not configured team ${configured_team_identifier}."
fi

identity="${RAWTHERAPEE_CODESIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-$signing_authority}}"
[[ -n "$identity" && "$identity" != "-" ]] ||
    die "No Developer ID Application identity is available for packaging."

actual_identifier="$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleIdentifier" \
        "${application}/Contents/Info.plist"
)"
[[ "$actual_identifier" == "$bundle_identifier" ]] ||
    die "Unexpected bundle identifier: ${actual_identifier}"

entitlements="$(/usr/bin/codesign -d --entitlements :- "$application" 2>/dev/null)"
printf '%s\n' "$entitlements" |
    /usr/bin/grep -q '<key>com.apple.security.app-sandbox</key>' ||
    die "The application is not signed with App Sandbox enabled."

/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"

log "validating the Apple notarization profile"
if ! /usr/bin/xcrun notarytool history \
    --keychain-profile "$notary_profile" \
    >/dev/null; then
    die "Notarization credentials are unavailable. Run: xcrun notarytool store-credentials ${notary_profile} --apple-id YOUR-APPLE-ID --team-id ${team_identifier}"
fi

version="$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "${application}/Contents/Info.plist"
)"
safe_version="$(printf '%s' "$version" | /usr/bin/tr -c 'A-Za-z0-9._-' '_')"
minimum_system_version="$(
    /usr/libexec/PlistBuddy \
        -c "Print :LSMinimumSystemVersionByArchitecture:arm64" \
        "${application}/Contents/Info.plist" \
        2>/dev/null ||
        printf '%s' "${MACOSX_DEPLOYMENT_TARGET:-26.0}"
)"
architectures="$(
    /usr/bin/lipo -archs "${application}/Contents/MacOS/rawtherapee-bin"
)"
if [[ "$architectures" == *" "* ]]; then
    architecture_label=Universal
else
    architecture_label="$architectures"
fi

artifact_base="RawTherapee_macOS_${minimum_system_version}_${architecture_label}_${safe_version}"
dmg_path="${output_directory}/${artifact_base}.dmg"
zip_path="${output_directory}/${artifact_base}.zip"

temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rawtherapee-package.XXXXXXXX")"
cleanup()
{
    /bin/rm -rf "$temporary_directory"
}
trap cleanup EXIT

/bin/mkdir -p "$output_directory"
/bin/rm -f "$dmg_path" "$zip_path"

log "submitting the signed application for notarization"
app_submission="${temporary_directory}/RawTherapee.app.zip"
/usr/bin/ditto \
    -c -k --sequesterRsrc --keepParent \
    "$application" \
    "$app_submission"
/usr/bin/xcrun notarytool submit \
    "$app_submission" \
    --keychain-profile "$notary_profile" \
    --wait
/usr/bin/xcrun stapler staple "$application"
/usr/bin/xcrun stapler validate "$application"
/usr/sbin/spctl --assess --type execute --verbose=4 "$application"

log "preparing the fancy disk image"
dmg_source="${temporary_directory}/dmg-source"
/bin/mkdir -p "$dmg_source"
/usr/bin/ditto "$application" "${dmg_source}/RawTherapee.app"
/bin/ln -s /Applications "${dmg_source}/Applications"

create_webloc()
{
    local name=$1
    local url=$2
    local path="${dmg_source}/${name}.webloc"

    /usr/bin/plutil -create xml1 "$path"
    /usr/bin/plutil -insert URL -string "$url" "$path"
}

create_webloc Website https://www.rawtherapee.com/
create_webloc Documentation https://rawpedia.rawtherapee.com/
create_webloc Forum https://discuss.pixls.us/c/software/rawtherapee
create_webloc \
    "Report Bug" \
    "https://github.com/RawTherapee/RawTherapee/issues/new?template=bug_report.md"

background="${temporary_directory}/rtdmg-bkgd.png"
magick \
    "${source_directory}/tools/osx/rtdmg-bkgd.png" \
    -pointsize 80 \
    -font /System/Library/Fonts/Supplemental/Arial.ttf \
    -fill Black \
    -draw "text 14,1307 '${version}'" \
    -fill Salmon \
    -draw "text 10,1300 '${version}'" \
    "$background"

create-dmg \
    --overwrite \
    --background "$background" \
    --volname "RawTherapee_${safe_version}" \
    --volicon "${source_directory}/tools/osx/rtdmg.icns" \
    --window-pos 72 72 \
    --window-size 1000 697 \
    --text-size 16 \
    --icon-size 80 \
    --icon RawTherapee.app 250 238 \
    --icon Applications 700 238 \
    --icon Website.webloc 300 487 \
    --icon Forum.webloc 420 487 \
    --icon "Report Bug.webloc" 540 487 \
    --icon Documentation.webloc 680 487 \
    --no-internet-enable \
    --eula "${source_directory}/LICENSE" \
    --hdiutil-verbose \
    --hide-extension Website.webloc \
    --hide-extension "Report Bug.webloc" \
    --hide-extension Forum.webloc \
    --hide-extension Documentation.webloc \
    --filesystem APFS \
    "$dmg_path" \
    "$dmg_source"

log "signing and notarizing the disk image"
/usr/bin/codesign \
    --force \
    --sign "$identity" \
    --timestamp \
    "$dmg_path"

dmg_submission="${temporary_directory}/${artifact_base}.dmg.zip"
/usr/bin/ditto -c -k --sequesterRsrc "$dmg_path" "$dmg_submission"
/usr/bin/xcrun notarytool submit \
    "$dmg_submission" \
    --keychain-profile "$notary_profile" \
    --wait
/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

log "building the distribution ZIP"
zip_folder="${temporary_directory}/${artifact_base}_folder"
/bin/mkdir -p "$zip_folder"
/usr/bin/ditto "$dmg_path" "${zip_folder}/$(basename "$dmg_path")"
/usr/bin/ditto \
    "${source_directory}/tools/osx/INSTALL.readme.rtf" \
    "${zip_folder}/install-readme.rtf"

cli_slices=()
while IFS= read -r cli_architecture; do
    [[ -n "$cli_architecture" ]] || continue
    cli_slice="${temporary_directory}/rawtherapee-cli-${cli_architecture}"
    /usr/bin/clang \
        -arch "$cli_architecture" \
        "-mmacosx-version-min=${minimum_system_version}" \
        -Os \
        "${support_directory}/RawTherapeeCLIShim.c" \
        -o "$cli_slice"
    cli_slices+=("$cli_slice")
done < <(printf '%s\n' "$architectures" | /usr/bin/tr ' ' '\n')

cli_output="${zip_folder}/rawtherapee-cli"
if (( ${#cli_slices[@]} == 1 )); then
    /usr/bin/ditto "${cli_slices[0]}" "$cli_output"
else
    /usr/bin/lipo -create "${cli_slices[@]}" -output "$cli_output"
fi

/usr/bin/codesign \
    --force \
    --sign "$identity" \
    --timestamp \
    --options runtime \
    --identifier "${bundle_identifier}.command-line" \
    "$cli_output"
/usr/bin/codesign --verify --strict --verbose=2 "$cli_output"

/usr/bin/ditto \
    -c -k --sequesterRsrc --keepParent \
    "$zip_folder" \
    "$zip_path"

log "submitting the final distribution ZIP for notarization"
/usr/bin/xcrun notarytool submit \
    "$zip_path" \
    --keychain-profile "$notary_profile" \
    --wait

log "artifacts ready"
printf 'DMG: %s\nZIP: %s\n' "$dmg_path" "$zip_path"
