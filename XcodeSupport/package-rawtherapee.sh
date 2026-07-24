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
require_command git
require_command magick
require_command xcrun
require_command zip

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
architectures="$(
    /usr/bin/lipo -archs "${application}/Contents/MacOS/rawtherapee-bin"
)"
primary_architecture="${architectures%% *}"
minimum_system_version="$(
    /usr/libexec/PlistBuddy \
        -c "Print :LSMinimumSystemVersionByArchitecture:${primary_architecture}" \
        "${application}/Contents/Info.plist" \
        2>/dev/null ||
        /usr/libexec/PlistBuddy \
            -c "Print :LSMinimumSystemVersion" \
            "${application}/Contents/Info.plist" \
            2>/dev/null ||
        printf '%s' "${MACOSX_DEPLOYMENT_TARGET:-26.0}"
)"
if [[ "$architectures" == *" "* ]]; then
    architecture_label=Universal
else
    architecture_label="$architectures"
fi

artifact_base="RawTherapee_MacOS_${minimum_system_version}_${architecture_label}_${safe_version}"
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
dmg_output="${zip_folder}/$(basename "$dmg_path")"
install_readme="${zip_folder}/install-readme.rtf"
/usr/bin/ditto "$dmg_path" "$dmg_output"
/usr/bin/ditto \
    "${source_directory}/tools/osx/INSTALL.readme.rtf" \
    "$install_readme"

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

about_output="${zip_folder}/About-this-build.txt"
parent_commit="$(
    git -C "$project_directory" rev-parse HEAD 2>/dev/null ||
        printf 'unavailable'
)"
rawtherapee_commit="$(
    git -C "$source_directory" rev-parse HEAD 2>/dev/null ||
        printf 'unavailable'
)"
sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
xcode_version="$(/usr/bin/xcodebuild -version | /usr/bin/paste -sd ' ' -)"
macos_version="$(/usr/bin/sw_vers -productVersion)"
build_time="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
dmg_checksum="$(/usr/bin/shasum -a 256 "$dmg_output" | /usr/bin/awk '{ print $1 }')"
cli_checksum="$(/usr/bin/shasum -a 256 "$cli_output" | /usr/bin/awk '{ print $1 }')"

if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    parent_repository="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
else
    parent_repository="$project_directory"
fi

if [[ -n "${GITHUB_SERVER_URL:-}" &&
      -n "${GITHUB_REPOSITORY:-}" &&
      -n "${GITHUB_RUN_ID:-}" ]]; then
    workflow_run="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
    workflow_run="local build"
fi

{
    printf 'RawTherapee macOS distribution\n'
    printf '================================\n\n'
    printf 'Application version: %s\n' "$version"
    printf 'Bundle identifier: %s\n' "$bundle_identifier"
    printf 'Minimum macOS: %s\n' "$minimum_system_version"
    printf 'Configuration: Distribution\n'
    printf 'Architectures: %s\n' "$architectures"
    printf 'Built at (UTC): %s\n\n' "$build_time"
    printf 'Parent repository: %s\n' "$parent_repository"
    printf 'Parent commit: %s\n' "$parent_commit"
    printf 'RawTherapee commit: %s\n' "$rawtherapee_commit"
    printf 'Git reference: %s\n' "${GITHUB_REF:-local}"
    printf 'Workflow run: %s\n\n' "$workflow_run"
    printf 'Runner: %s (%s)\n' "${RUNNER_OS:-macOS}" "$(/usr/bin/uname -m)"
    printf 'macOS: %s\n' "$macos_version"
    printf 'Xcode: %s\n' "$xcode_version"
    printf 'macOS SDK: %s\n\n' "$sdk_version"
    printf 'Signing: Developer ID Application with hardened runtime and App Sandbox\n'
    printf 'Notarization: application and DMG accepted by Apple\n'
    printf 'Final ZIP: submitted to Apple after this exact archive is created\n'
    printf 'Stapling: application and DMG tickets stapled and validated\n\n'
    printf 'Files in this archive:\n'
    printf '  install-readme.rtf\n'
    printf '  %s\n' "$(basename "$dmg_output")"
    printf '  rawtherapee-cli\n'
    printf '  About-this-build.txt\n\n'
    printf 'DMG SHA-256: %s\n' "$dmg_checksum"
    printf 'CLI SHA-256: %s\n' "$cli_checksum"
} > "$about_output"

# Store exactly the four distribution files at the ZIP root. -X omits
# platform-specific metadata entries and -j prevents parent folder nesting.
/usr/bin/zip \
    -X -j -0 \
    "$zip_path" \
    "$install_readme" \
    "$dmg_output" \
    "$cli_output" \
    "$about_output"

log "submitting the final distribution ZIP for notarization"
/usr/bin/xcrun notarytool submit \
    "$zip_path" \
    --keychain-profile "$notary_profile" \
    --wait

log "artifacts ready"
printf 'DMG: %s\nZIP: %s\n' "$dmg_path" "$zip_path"
