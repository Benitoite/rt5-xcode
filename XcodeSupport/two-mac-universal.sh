#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

die()
{
    printf 'RawTherapee two-Mac build error: %s\n' "$*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_directory="$(cd "${script_directory}/.." && pwd)"
mode="${1:-}"
case "$mode" in
    intel|arm)
        ;;
    *)
        die "Usage: $0 intel | arm"
        ;;
esac

icloud_directory="$HOME/Library/Mobile Documents/com~apple~CloudDocs/RawTherapee-Universal"
repository_revision="$(
    git -C "$project_directory" rev-parse --short=12 HEAD
)"
archive_name="RawTherapee-Intel-${repository_revision}.zip"
icloud_archive="${icloud_directory}/${archive_name}"
temporary_root="${TMPDIR:-/tmp}"

[[ -z "$(
    git -C "$project_directory" \
        status --porcelain --ignore-submodules=none
)" ]] || die "Use the same clean repository commit on both Macs."

case "$mode" in
    intel)
        [[ "$(uname -m)" == "x86_64" ]] ||
            die "Run the intel command on the Intel Mac."

        xcodebuild \
            -project "${project_directory}/RawTherapee5.xcodeproj" \
            -scheme RawTherapee \
            -configuration Release \
            -destination "generic/platform=macOS" \
            -derivedDataPath "${project_directory}/DerivedData" \
            ARCHS=x86_64 \
            MACOSX_DEPLOYMENT_TARGET=12.0 \
            ONLY_ACTIVE_ARCH=YES \
            build

        intel_app="${project_directory}/DerivedData/Build/Products/Release/RawTherapee.app"
        intel_engine="${intel_app}/Contents/MacOS/rawtherapee-bin"
        [[ -x "$intel_engine" ]] ||
            die "The Intel application was not produced."
        [[ "$(/usr/bin/lipo -archs "$intel_engine")" == "x86_64" ]] ||
            die "The Intel application is not a thin x86_64 build."

        temporary_directory="$(
            /usr/bin/mktemp -d \
                "${temporary_root%/}/rawtherapee-intel.XXXXXXXX"
        )"
        trap '/bin/rm -rf "$temporary_directory"' EXIT
        local_archive="${temporary_directory}/${archive_name}"

        /usr/bin/ditto \
            -c -k --sequesterRsrc --keepParent \
            "$intel_app" \
            "$local_archive"
        /usr/bin/unzip -tq "$local_archive"

        /bin/mkdir -p "$icloud_directory"
        upload_path="${icloud_archive}.uploading"
        /bin/rm -f "$upload_path"
        /usr/bin/ditto "$local_archive" "$upload_path"
        /bin/mv -f "$upload_path" "$icloud_archive"

        printf 'Intel ZIP copied to iCloud Drive:\n%s\n' "$icloud_archive"
        ;;

    arm)
        [[ "$(uname -m)" == "arm64" ]] ||
            die "Run the arm command on the Apple Silicon Mac."
        [[ -f "$icloud_archive" ]] ||
            die "The matching Intel ZIP has not synced to this Mac: ${icloud_archive}"

        temporary_directory="$(
            /usr/bin/mktemp -d \
                "${temporary_root%/}/rawtherapee-universal.XXXXXXXX"
        )"
        trap '/bin/rm -rf "$temporary_directory"' EXIT
        local_archive="${temporary_directory}/${archive_name}"
        extracted_directory="${temporary_directory}/extracted"

        /usr/bin/ditto "$icloud_archive" "$local_archive"
        /usr/bin/unzip -tq "$local_archive"
        /bin/mkdir -p "$extracted_directory"
        /usr/bin/ditto -x -k "$local_archive" "$extracted_directory"

        intel_app="${extracted_directory}/RawTherapee.app"
        intel_engine="${intel_app}/Contents/MacOS/rawtherapee-bin"
        [[ -x "$intel_engine" ]] ||
            die "The transferred Intel application is missing."
        [[ "$(/usr/bin/lipo -archs "$intel_engine")" == "x86_64" ]] ||
            die "The transferred application is not thin x86_64."

        xcodebuild \
            -project "${project_directory}/RawTherapee5.xcodeproj" \
            -scheme "RawTherapee Distribution" \
            -configuration Distribution \
            -destination "generic/platform=macOS" \
            -derivedDataPath "${project_directory}/DerivedData" \
            ARCHS=arm64 \
            MACOSX_DEPLOYMENT_TARGET=26.0 \
            ONLY_ACTIVE_ARCH=YES \
            RAWTHERAPEE_UNIVERSAL_COUNTERPART_APP="$intel_app" \
            build

        universal_app="${project_directory}/DerivedData/Build/Products/Distribution/RawTherapee.app"
        universal_engine="${universal_app}/Contents/MacOS/rawtherapee-bin"
        architectures="$(/usr/bin/lipo -archs "$universal_engine")"
        if [[ "$architectures" != "arm64 x86_64" &&
              "$architectures" != "x86_64 arm64" ]]; then
            die "The completed application is not universal: ${architectures}"
        fi

        universal_info="${universal_app}/Contents/Info.plist"
        arm64_minimum="$(
            /usr/libexec/PlistBuddy \
                -c "Print :LSMinimumSystemVersionByArchitecture:arm64" \
                "$universal_info"
        )"
        x86_64_minimum="$(
            /usr/libexec/PlistBuddy \
                -c "Print :LSMinimumSystemVersionByArchitecture:x86_64" \
                "$universal_info"
        )"
        overriding_minimum="$(
            /usr/libexec/PlistBuddy \
                -c "Print :LSMinimumSystemVersion" \
                "$universal_info" \
                2>/dev/null ||
                true
        )"
        [[ "$arm64_minimum" == "26.0" ]] ||
            die "The arm64 minimum macOS is ${arm64_minimum}, not 26.0."
        [[ "$x86_64_minimum" == "12.0" ]] ||
            die "The x86_64 minimum macOS is ${x86_64_minimum}, not 12.0."
        [[ -z "$overriding_minimum" ]] ||
            die "The universal app has an overriding LSMinimumSystemVersion: ${overriding_minimum}"

        /usr/bin/codesign \
            --verify --deep --strict --verbose=2 \
            "$universal_app"
        printf 'Universal distribution completed:\n%s/dist\n' \
            "$project_directory"
        ;;

esac
