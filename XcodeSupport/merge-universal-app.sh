#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

die()
{
    printf 'RawTherapee universal merge error: %s\n' "$*" >&2
    exit 1
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' was not found."
}

arm64_application="${1:-}"
x86_64_application="${2:-}"

[[ -d "$arm64_application" ]] ||
    die "The arm64 application was not found: ${arm64_application:-<empty>}"
[[ -d "$x86_64_application" ]] ||
    die "The x86_64 application was not found: ${x86_64_application:-<empty>}"

require_command file
require_command lipo
require_command otool
require_command plutil

plist_buddy=/usr/libexec/PlistBuddy
[[ -x "$plist_buddy" ]] ||
    die "PlistBuddy was not found."

arm64_contents="${arm64_application}/Contents"
x86_64_contents="${x86_64_application}/Contents"
arm64_engine="${arm64_contents}/MacOS/rawtherapee-bin"
x86_64_engine="${x86_64_contents}/MacOS/rawtherapee-bin"
arm64_info="${arm64_contents}/Info.plist"
x86_64_info="${x86_64_contents}/Info.plist"
arm64_about="${arm64_contents}/Resources/AboutThisBuild.txt"
x86_64_about="${x86_64_contents}/Resources/AboutThisBuild.txt"

for required_file in \
    "$arm64_engine" \
    "$x86_64_engine" \
    "$arm64_info" \
    "$x86_64_info" \
    "$arm64_about" \
    "$x86_64_about"
do
    [[ -f "$required_file" ]] ||
        die "A required application file is missing: ${required_file}"
done

architecture_of()
{
    /usr/bin/lipo -archs "$1"
}

[[ "$(architecture_of "$arm64_engine")" == "arm64" ]] ||
    die "The primary application is not a thin arm64 build."
[[ "$(architecture_of "$x86_64_engine")" == "x86_64" ]] ||
    die "The countercomponent application is not a thin x86_64 build."

plist_value()
{
    "$plist_buddy" -c "Print :$2" "$1" 2>/dev/null || true
}

for version_key in \
    CFBundleIdentifier \
    CFBundleShortVersionString \
    CFBundleVersion
do
    arm64_value="$(plist_value "$arm64_info" "$version_key")"
    x86_64_value="$(plist_value "$x86_64_info" "$version_key")"
    if [[ -n "$arm64_value" && -n "$x86_64_value" &&
          "$arm64_value" != "$x86_64_value" ]]; then
        die "${version_key} differs between components: arm64=${arm64_value}, x86_64=${x86_64_value}"
    fi
done

minimum_macos_from_binary()
{
    /usr/bin/otool -l "$1" |
        /usr/bin/awk '
            $1 == "cmd" && $2 == "LC_BUILD_VERSION" {
                in_build_version = 1
                in_legacy_version = 0
                next
            }
            $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" {
                in_build_version = 0
                in_legacy_version = 1
                next
            }
            in_build_version && $1 == "minos" {
                print $2
                exit
            }
            in_legacy_version && $1 == "version" {
                print $2
                exit
            }
        '
}

minimum_macos_for_component()
{
    local application=$1
    local architecture=$2
    local engine=$3
    local info="${application}/Contents/Info.plist"
    local minimum

    minimum="$(minimum_macos_from_binary "$engine")"
    if [[ -z "$minimum" ]]; then
        minimum="$(
            plist_value \
                "$info" \
                "LSMinimumSystemVersionByArchitecture:${architecture}"
        )"
    fi
    if [[ -z "$minimum" ]]; then
        minimum="$(plist_value "$info" LSMinimumSystemVersion)"
    fi
    [[ -n "$minimum" ]] ||
        die "Could not determine the minimum macOS version for ${architecture}."
    printf '%s' "$minimum"
}

minimum_arm64_version="$(
    minimum_macos_for_component \
        "$arm64_application" \
        arm64 \
        "$arm64_engine"
)"
minimum_x86_64_version="$(
    minimum_macos_for_component \
        "$x86_64_application" \
        x86_64 \
        "$x86_64_engine"
)"

temporary_outputs=()
cleanup()
{
    local output
    for output in "${temporary_outputs[@]}"; do
        /bin/rm -f "$output"
    done
}
trap cleanup EXIT

merged_count=0
while IFS= read -r -d '' arm64_candidate; do
    if ! /usr/bin/file -b "$arm64_candidate" |
        /usr/bin/grep -q 'Mach-O'; then
        continue
    fi

    relative_path="${arm64_candidate#"${arm64_application}/"}"
    x86_64_candidate="${x86_64_application}/${relative_path}"
    [[ -f "$x86_64_candidate" ]] ||
        die "The x86_64 app is missing Mach-O file: ${relative_path}"
    /usr/bin/file -b "$x86_64_candidate" |
        /usr/bin/grep -q 'Mach-O' ||
        die "The x86_64 counterpart is not Mach-O: ${relative_path}"

    [[ "$(architecture_of "$arm64_candidate")" == "arm64" ]] ||
        die "The primary component is not thin arm64: ${relative_path}"
    [[ "$(architecture_of "$x86_64_candidate")" == "x86_64" ]] ||
        die "The countercomponent is not thin x86_64: ${relative_path}"

    universal_candidate="${arm64_candidate}.universal-$$"
    temporary_outputs+=("$universal_candidate")
    /usr/bin/lipo \
        -create \
        "$arm64_candidate" \
        "$x86_64_candidate" \
        -output "$universal_candidate"
    /bin/chmod "$(/usr/bin/stat -f '%Lp' "$arm64_candidate")" \
        "$universal_candidate"
    /bin/mv "$universal_candidate" "$arm64_candidate"
    merged_count=$((merged_count + 1))
done < <(
    /usr/bin/find \
        "${arm64_contents}/MacOS" \
        "${arm64_contents}/Frameworks" \
        -type f -print0
)

(( merged_count > 0 )) ||
    die "The arm64 application contained no Mach-O files to merge."

while IFS= read -r -d '' x86_64_candidate; do
    if ! /usr/bin/file -b "$x86_64_candidate" |
        /usr/bin/grep -q 'Mach-O'; then
        continue
    fi

    relative_path="${x86_64_candidate#"${x86_64_application}/"}"
    arm64_candidate="${arm64_application}/${relative_path}"
    [[ -f "$arm64_candidate" ]] ||
        die "The arm64 app is missing Mach-O file: ${relative_path}"
    /usr/bin/file -b "$arm64_candidate" |
        /usr/bin/grep -q 'Mach-O' ||
        die "The arm64 counterpart is not Mach-O: ${relative_path}"
done < <(
    /usr/bin/find \
        "${x86_64_contents}/MacOS" \
        "${x86_64_contents}/Frameworks" \
        -type f -print0
)

while IFS= read -r -d '' universal_candidate; do
    if ! /usr/bin/file -b "$universal_candidate" |
        /usr/bin/grep -q 'Mach-O'; then
        continue
    fi

    universal_architectures="$(architecture_of "$universal_candidate")"
    if [[ "$universal_architectures" != "arm64 x86_64" &&
          "$universal_architectures" != "x86_64 arm64" ]]; then
        relative_path="${universal_candidate#"${arm64_application}/"}"
        die "The merged file is not exactly arm64 and x86_64 (${universal_architectures}): ${relative_path}"
    fi
done < <(
    /usr/bin/find \
        "${arm64_contents}/MacOS" \
        "${arm64_contents}/Frameworks" \
        -type f -print0
)

"$plist_buddy" \
    -c "Delete :LSMinimumSystemVersion" \
    "$arm64_info" >/dev/null 2>&1 || true
if ! "$plist_buddy" \
    -c "Set :LSMinimumSystemVersionByArchitecture:arm64 ${minimum_arm64_version}" \
    "$arm64_info" >/dev/null 2>&1; then
    "$plist_buddy" \
        -c "Add :LSMinimumSystemVersionByArchitecture:arm64 string ${minimum_arm64_version}" \
        "$arm64_info"
fi
if ! "$plist_buddy" \
    -c "Set :LSMinimumSystemVersionByArchitecture:x86_64 ${minimum_x86_64_version}" \
    "$arm64_info" >/dev/null 2>&1; then
    "$plist_buddy" \
        -c "Add :LSMinimumSystemVersionByArchitecture:x86_64 string ${minimum_x86_64_version}" \
        "$arm64_info"
fi
/usr/bin/plutil -lint "$arm64_info" >/dev/null

combined_about="${arm64_about}.universal-$$"
temporary_outputs+=("$combined_about")
{
    printf 'RawTherapee universal macOS application\n'
    printf '=======================================\n'
    printf 'Version and resources: arm64 component\n'
    printf 'Architectures: arm64 x86_64\n'
    printf 'Minimum macOS (arm64): %s\n' "$minimum_arm64_version"
    printf 'Minimum macOS (x86_64): %s\n' "$minimum_x86_64_version"
    printf 'Merged Mach-O files: %s\n' "$merged_count"
    printf '\narm64 component build\n'
    printf '%s\n' '---------------------'
    /bin/cat "$arm64_about"
    printf '\nx86_64 component build\n'
    printf '%s\n' '----------------------'
    /bin/cat "$x86_64_about"
} > "$combined_about"
/bin/mv "$combined_about" "$arm64_about"

printf \
    'Universal app merged: %s Mach-O files; arm64 minimum macOS %s; x86_64 minimum macOS %s\n' \
    "$merged_count" \
    "$minimum_arm64_version" \
    "$minimum_x86_64_version"
