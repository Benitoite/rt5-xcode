#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

log()
{
    printf '\n\033[1mRawTherapee Xcode: %s\033[0m\n' "$*"
}

die()
{
    printf 'RawTherapee Xcode error: %s\n' "$*" >&2
    exit 1
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' was not found."
}

source_directory="${PROJECT_DIR}/RawTherapee5/rawtherapee"
support_directory="${PROJECT_DIR}/XcodeSupport"
configuration="${CONFIGURATION:-Debug}"
architecture="${CURRENT_ARCH:-$(uname -m)}"
bundle_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-com.rawtherapee.rawtherapee5}"
sandbox_enabled="${ENABLE_APP_SANDBOX:-NO}"

if [[ "$architecture" == "undefined_arch" || -z "$architecture" ]]; then
    architecture="$(uname -m)"
fi

case "$architecture" in
    arm64|x86_64)
        ;;
    *)
        die "Unsupported architecture: ${architecture}"
        ;;
esac

[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
    die "Invalid product bundle identifier: ${bundle_identifier}"

[[ -f "${source_directory}/CMakeLists.txt" ]] ||
    die "RawTherapee source was not found at ${source_directory}."
[[ -f "${source_directory}/tools/osx/macosx_bundle.sh" ]] ||
    die "RawTherapee's macOS bundle script is missing."

if [[ -n "${RAWTHERAPEE_HOMEBREW_PREFIX:-}" ]]; then
    homebrew_prefix="$RAWTHERAPEE_HOMEBREW_PREFIX"
else
    homebrew_executable=
    if command -v brew >/dev/null 2>&1; then
        homebrew_executable="$(command -v brew)"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
        homebrew_executable=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
        homebrew_executable=/usr/local/bin/brew
    else
        die "Homebrew was not found. Install it or set RAWTHERAPEE_HOMEBREW_PREFIX."
    fi
    homebrew_prefix="$("$homebrew_executable" --prefix)"
fi

[[ -d "$homebrew_prefix" ]] ||
    die "Homebrew prefix does not exist: ${homebrew_prefix}"

export PATH="${homebrew_prefix}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_PATH="${homebrew_prefix}/lib/pkgconfig:${homebrew_prefix}/share/pkgconfig:${homebrew_prefix}/opt/libffi/lib/pkgconfig:${homebrew_prefix}/opt/expat/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export GIT_CEILING_DIRECTORIES="$(dirname "$PROJECT_DIR")"

require_command cmake
require_command git
require_command pkg-config
require_command xcodebuild

if [[ ! -d "${SDKROOT:-}" ]]; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export SDKROOT
fi

required_packages=(
    gtkmm-3.0
    gtk+-3.0
    gtk-mac-integration-gtk3
    lensfun
    libiptcdata
    fftw3f
    lcms2
    exiv2
    libjxl
    libtiff-4
    libpng
    simde
)

missing_packages=()
for package in "${required_packages[@]}"; do
    if ! pkg-config --exists "$package"; then
        missing_packages+=("$package")
    fi
done

if (( ${#missing_packages[@]} > 0 )); then
    die "Missing pkg-config packages: ${missing_packages[*]}. See XcodeSupport/README.md."
fi

libomp_library="${homebrew_prefix}/opt/libomp/lib/libomp.dylib"
[[ -f "$libomp_library" ]] ||
    die "libomp was not found at ${libomp_library}."

case "$configuration" in
    Debug)
        cmake_configuration=Debug
        link_time_optimization=OFF
        ;;
    Release|Distribution)
        cmake_configuration=Release
        link_time_optimization=ON
        ;;
    *)
        die "Unsupported Xcode build configuration: ${configuration}"
        ;;
esac

cmake_build_directory="${DERIVED_FILE_DIR}/RawTherapee-CMake/${configuration}-${architecture}"
stage_directory="${cmake_build_directory}/${cmake_configuration}"
product="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
launcher="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"
saved_launcher="${DERIVED_FILE_DIR}/RawTherapeeLauncher-${architecture}"
bundle="${cmake_build_directory}/RawTherapee.app"

[[ "$product" == "${TARGET_BUILD_DIR}/"*.app ]] ||
    die "Refusing to replace an unexpected product path: ${product}"
[[ -x "$launcher" ]] ||
    die "The Xcode-built launcher is missing: ${launcher}"

/usr/bin/ditto "$launcher" "$saved_launcher"

openmp_flags="-arch ${architecture} -Xpreprocessor -fopenmp -I${homebrew_prefix}/opt/libomp/include -I${homebrew_prefix}/include -I${homebrew_prefix}/opt/gdk-pixbuf/include -I${homebrew_prefix}/opt/libiconv/include -I${homebrew_prefix}/opt/libxml2/include -I${homebrew_prefix}/opt/expat/include -I${homebrew_prefix}/opt/libtiff/include"
compiler_flags="-arch ${architecture} -Wno-pass-failed -Wno-deprecated-register -Wno-unused-command-line-argument"
linker_flags="-L${homebrew_prefix}/lib -Wl,-rpath,${homebrew_prefix}/lib -L${homebrew_prefix}/opt/gdk-pixbuf/lib -L${homebrew_prefix}/opt/libomp/lib -L${homebrew_prefix}/opt/expat/lib"

log "configuring the CMake source graph with the Xcode generator"
cmake \
    -S "$source_directory" \
    -B "$cmake_build_directory" \
    -G Xcode \
    -DCMAKE_BUILD_TYPE="$cmake_configuration" \
    -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
    -DCMAKE_C_COMPILER=/usr/bin/clang \
    -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_AR=/usr/bin/ar \
    -DCMAKE_RANLIB=/usr/bin/ranlib \
    -DCMAKE_C_FLAGS="$compiler_flags" \
    -DCMAKE_CXX_FLAGS="$compiler_flags" \
    -DCMAKE_EXE_LINKER_FLAGS="$linker_flags" \
    -DOpenMP_C_FLAGS="$openmp_flags" \
    -DOpenMP_CXX_FLAGS="$openmp_flags" \
    -DOpenMP_C_LIB_NAMES=libomp \
    -DOpenMP_CXX_LIB_NAMES=libomp \
    -DOpenMP_libomp_LIBRARY="$libomp_library" \
    -DLOCAL_PREFIX="$homebrew_prefix" \
    -DWITH_SIMDE=ON \
    -DWITH_SYSTEM_FMT=ON \
    -DWITH_LTO="$link_time_optimization" \
    -DOSX_DEV_BUILD=ON \
    -DLENSFUNDBDIR=../Resources/share/lensfun \
    -DCODESIGNID:STRING=- \
    -DFANCY_DMG=OFF \
    -DBUNDLE_BASE_INSTALL_DIR="${stage_directory}/MacOS" \
    -DDATADIR="${stage_directory}/Resources/share" \
    -DLIBDIR="${stage_directory}/Frameworks" \
    -DDOCDIR="${stage_directory}/Resources/share/doc" \
    -DCREDITSDIR="${stage_directory}/Resources" \
    -DLICENCEDIR="${stage_directory}/Resources" \
    -DDESKTOPDIR="${stage_directory}/Resources/share/applications" \
    -DICONSDIR="${stage_directory}/Resources/share/icons" \
    -DAPPDATADIR="${stage_directory}/Resources/share/metainfo" \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_ENABLE_USER_SCRIPT_SANDBOXING=NO

generated_config="${cmake_build_directory}/rtgui/config.h"
[[ -f "$generated_config" ]] ||
    die "CMake did not generate rtgui/config.h."

# OSX_DEV_BUILD makes these paths relative to the real executable. Installation
# destinations remain absolute and safely confined to DerivedData.
/usr/bin/perl -pi -e \
    's{^#define DATA_SEARCH_PATH ".*"$}{#define DATA_SEARCH_PATH "../Resources/share"}' \
    "$generated_config"
/usr/bin/perl -pi -e \
    's{^#define DOC_SEARCH_PATH ".*"$}{#define DOC_SEARCH_PATH "../Resources"}' \
    "$generated_config"
/usr/bin/perl -pi -e \
    's{^#define CREDITS_SEARCH_PATH ".*"$}{#define CREDITS_SEARCH_PATH "../Resources"}' \
    "$generated_config"
/usr/bin/perl -pi -e \
    's{^#define LICENCE_SEARCH_PATH ".*"$}{#define LICENCE_SEARCH_PATH "../Resources"}' \
    "$generated_config"

jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
log "building and installing RawTherapee through its generated Xcode project"
cmake \
    --build "$cmake_build_directory" \
    --config "$cmake_configuration" \
    --target install \
    --parallel "$jobs"

upstream_bundle_script="${source_directory}/tools/osx/macosx_bundle.sh"
compatibility_bundle_script="${support_directory}/macosx_bundle_compat.sh"
bundle_script_source="$upstream_bundle_script"

# RawTherapee releases before the portable Homebrew bundler can preserve
# package-manager symlinks and omit keg-only libraries. Use the integration's
# compatibility copy for those revisions without changing the submodule.
if ! /usr/bin/grep -q 'copy_tree_dereference' "$upstream_bundle_script"; then
    [[ -f "$compatibility_bundle_script" ]] ||
        die "The macOS compatibility bundle script is missing."
    log "using the Xcode compatibility bundle script for this RawTherapee revision"
    bundle_script_source="$compatibility_bundle_script"
fi

patched_bundle_script="${cmake_build_directory}/macosx_bundle_xcode.sh"
/usr/bin/awk '
    /^# Codesign the app/ { exit }
    {
        gsub(/cmake \.\./, "cmake .")
        gsub(/sudo /, "")
        print
    }
' "$bundle_script_source" > "$patched_bundle_script"

source_git_directory="$(
    git -C "$source_directory" rev-parse --absolute-git-dir 2>/dev/null
)" || die "RawTherapee source is not a valid Git worktree."

log "assembling the macOS application bundle"
(
    cd "$cmake_build_directory"
    env \
        GIT_DIR="$source_git_directory" \
        GIT_WORK_TREE="$source_directory" \
        PROJECT_NAME=RawTherapee \
        PROJECT_SOURCE_DIR="$source_directory" \
        CMAKE_BUILD_TYPE="$cmake_configuration" \
        PROC_BIT_DEPTH=64 \
        GTK_PREFIX="$homebrew_prefix" \
        /bin/bash "$patched_bundle_script"
)

[[ -x "${bundle}/Contents/MacOS/rawtherapee" ]] ||
    die "The bundle did not contain the RawTherapee executable."
[[ -x "${bundle}/Contents/MacOS/rawtherapee-cli" ]] ||
    die "The bundle did not contain rawtherapee-cli."

/bin/mv \
    "${bundle}/Contents/MacOS/rawtherapee" \
    "${bundle}/Contents/MacOS/rawtherapee-bin"
/bin/mv \
    "${bundle}/Contents/MacOS/rawtherapee-cli" \
    "${bundle}/Contents/MacOS/rawtherapee-cli-bin"
/usr/bin/ditto "$saved_launcher" "${bundle}/Contents/MacOS/rawtherapee"
/usr/bin/ditto "$saved_launcher" "${bundle}/Contents/MacOS/rawtherapee-cli"

# The launcher supplies bundle-relative GTK paths at runtime. The upstream
# values intentionally point at /Applications and would defeat Xcode's Run.
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" \
    "${bundle}/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier ${bundle_identifier}" \
    "${bundle}/Contents/Info.plist"

frameworks="${bundle}/Contents/Frameworks"

relocate_macho()
{
    local binary=$1
    local dependency
    local dependency_name
    local identifier
    local rpath
    local desired_rpath

    /bin/chmod u+w "$binary"

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            /System/*|/usr/lib/*|@executable_path/*|@loader_path/*|@rpath/*)
                continue
                ;;
        esac

        dependency_name="$(basename "$dependency")"
        if [[ -e "${frameworks}/${dependency_name}" ]]; then
            install_name_tool \
                -change "$dependency" "@rpath/${dependency_name}" "$binary"
        fi
    done < <(otool -L "$binary" | /usr/bin/awk 'NR > 1 { print $1 }')

    identifier="$(otool -D "$binary" 2>/dev/null | /usr/bin/awk 'NR == 2 { print; exit }')"
    if [[ -n "$identifier" && "$binary" == "${frameworks}/"* ]]; then
        install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
    fi

    while IFS= read -r rpath; do
        case "$rpath" in
            /Applications/*|/opt/homebrew/*|/opt/local/*|/usr/local/*|"${cmake_build_directory}"*)
                install_name_tool -delete_rpath "$rpath" "$binary" 2>/dev/null || true
                ;;
        esac
    done < <(
        otool -l "$binary" |
            /usr/bin/awk '/cmd LC_RPATH/ { getline; getline; print $2 }'
    )

    if [[ "$binary" == "${frameworks}/"* ]]; then
        desired_rpath="@loader_path"
    else
        desired_rpath="@executable_path/../Frameworks"
    fi
    install_name_tool -add_rpath "$desired_rpath" "$binary" 2>/dev/null || true
}

log "relocating bundled Mach-O dependencies"
while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
        relocate_macho "$candidate"
    fi
done < <(
    /usr/bin/find \
        "${bundle}/Contents/MacOS" \
        "${bundle}/Contents/Frameworks" \
        -type f -print0
)

invalid_dependency=0
while IFS= read -r -d '' candidate; do
    if ! /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
        continue
    fi

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            /Applications/RawTherapee.app/*|/opt/homebrew/*|/opt/local/*|/usr/local/*)
                printf 'Non-relocatable dependency in %s: %s\n' \
                    "$candidate" "$dependency" >&2
                invalid_dependency=1
                ;;
            @rpath/*)
                dependency_name="$(basename "$dependency")"
                if [[ ! -e "${frameworks}/${dependency_name}" ]]; then
                    printf 'Missing @rpath dependency for %s: %s\n' \
                        "$candidate" "$dependency" >&2
                    invalid_dependency=1
                fi
                ;;
        esac
    done < <(otool -L "$candidate" | /usr/bin/awk 'NR > 1 { print $1 }')
done < <(
    /usr/bin/find \
        "${bundle}/Contents/MacOS" \
        "${bundle}/Contents/Frameworks" \
        -type f -print0
)

(( invalid_dependency == 0 )) ||
    die "The completed app contains invalid dynamic-library references."

log "copying the relocatable bundle into Xcode's product directory"
/bin/rm -rf "$product"
/usr/bin/ditto "$bundle" "$product"

sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$sign_identity" ]]; then
    sign_identity=-
fi

codesign_options=(
    --force
    --sign "$sign_identity"
)
if [[ "$sign_identity" == "-" ]]; then
    codesign_options+=(--timestamp=none)
else
    codesign_options+=(--timestamp --options runtime)
fi

main_entitlements="${CODE_SIGN_ENTITLEMENTS:-}"
if [[ -n "$main_entitlements" && "$main_entitlements" != /* ]]; then
    main_entitlements="${PROJECT_DIR}/${main_entitlements}"
fi
if [[ "$sandbox_enabled" == "YES" ]]; then
    [[ -f "$main_entitlements" ]] ||
        die "App Sandbox entitlements were not found: ${main_entitlements}"
fi

while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
        # Signing CFBundleExecutable directly makes codesign validate the
        # enclosing app. Xcode signs it and the app after this phase.
        if [[ "$candidate" == "${product}/Contents/MacOS/rawtherapee" ]]; then
            continue
        fi
        candidate_codesign_options=("${codesign_options[@]}")
        if [[ "$sandbox_enabled" == "YES" ]]; then
            case "$candidate" in
                "${product}/Contents/MacOS/rawtherapee-bin")
                    candidate_codesign_options+=(
                        --identifier "${bundle_identifier}.engine"
                    )
                    ;;
                "${product}/Contents/MacOS/rawtherapee-cli")
                    candidate_codesign_options+=(
                        # Matching the enclosing app identifier lets sandboxd
                        # associate this alternate entry point with the app's
                        # Info.plist and container when launched from Terminal.
                        --identifier "$bundle_identifier"
                        --entitlements "$main_entitlements"
                    )
                    ;;
                "${product}/Contents/MacOS/rawtherapee-cli-bin")
                    candidate_codesign_options+=(
                        --identifier "${bundle_identifier}.cli-engine"
                    )
                    ;;
            esac
        fi
        /usr/bin/codesign \
            "${candidate_codesign_options[@]}" \
            "$candidate"
    fi
done < <(
    /usr/bin/find \
        "${product}/Contents/MacOS" \
        "${product}/Contents/Frameworks" \
        -type f -print0
)

log "bundle ready at ${product}"
