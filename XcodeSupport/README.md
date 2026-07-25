# RawTherapee Xcode integration

`RawTherapee5.xcodeproj` is the macOS application project. Build or Run its
`RawTherapee` scheme normally. The first build takes substantially longer than
later incremental builds.

RawTherapee itself is a Git submodule at `RawTherapee5/rawtherapee`; its source
is not duplicated in this repository.

Clone this repository with its submodule:

```sh
git clone --recurse-submodules YOUR-REPOSITORY-URL
cd RT5-XCODE
```

If the repository was cloned without submodules:

```sh
git submodule update --init --recursive
```

## Quick start

1. Open `RawTherapee5.xcodeproj`.
2. Select the `RawTherapee` scheme and the **My Mac** destination.
3. Use **Product > Run** to build, bundle, sign, and launch RawTherapee.

The finished `RawTherapee.app` appears in Xcode's normal Products group. Product
Clean removes the outer target; deleting this project's DerivedData also removes
the generated CMake Xcode project and all staged upstream build output.

The native Xcode target compiles a small launcher, asks CMake to generate an
Xcode build graph for the unmodified `RawTherapee5/rawtherapee` checkout,
builds the C++ targets with Clang, stages the upstream resources, and produces a
relocatable `RawTherapee.app` in Xcode's normal product directory.

All generated files and CMake installation output are kept under DerivedData.
Nothing is generated or changed inside the nested RawTherapee checkout.

## Selecting a RawTherapee version

The repository records a tested public RawTherapee commit. To build another
release, development branch, tag, or future revision:

```sh
cd RawTherapee5/rawtherapee
git fetch --tags origin
git checkout YOUR-BRANCH-TAG-OR-COMMIT
cd ../..
git add RawTherapee5/rawtherapee
git commit -m "Update RawTherapee submodule"
```

Older RawTherapee revisions use the GPL-licensed
`XcodeSupport/macosx_bundle_compat.sh` copy because their upstream bundler is
not relocatable with current Homebrew layouts. Newer compatible revisions use
their own upstream bundle script automatically. The submodule is never patched
or modified by the Xcode build.

## Requirements

- Xcode 14 with its command-line tools selected
- CMake and Homebrew
- A native-architecture Homebrew dependency installation
- `create-dmg` and ImageMagick for the distribution disk image
- macOS 12.5 (Monterey) or later for the Xcode 14 build environment

The dependency set used by RawTherapee's macOS CI can be installed with:

```sh
brew install \
  adwaita-icon-theme automake exiv2 expat fftw fmt gtk+3 gtkmm3 \
  gtk-mac-integration jpeg-xl lensfun libiptcdata libomp libpng \
  libsigc++@2 libtiff little-cms2 pkgconfig shared-mime-info \
  create-dmg imagemagick
```

Apple Silicon builds also require SIMDe:

```sh
brew install simde
```

The build validates the required pkg-config modules and reports any missing
ones. SIMDe is enabled and validated only for arm64 builds; Intel builds use
RawTherapee's native x86 SIMD implementation. Set `RAWTHERAPEE_HOMEBREW_PREFIX`
in the scheme's build environment only when Homebrew is not installed at the
prefix returned by `brew --prefix`.

## Build configurations

- Debug builds RawTherapee with debug definitions and without LTO.
- Release enables RawTherapee's LTO option.
- Debug and Release use portable ad-hoc signing and do not require an Apple
  Developer account. They are intentionally unsandboxed for local development.
- Distribution uses the Release CMake build, hardened runtime, secure
  timestamps, bundle identifier `com.rawtherapee.rawtherapee5`, and the
  Developer ID Application identity installed for the current developer.
- Distribution enables App Sandbox using the same broad filesystem exception
  used by RawTherapee's upstream macOS bundle.
- Local builds default to a macOS 12 deployment target. Dependencies must also
  be built for macOS 12 or an earlier deployment target.
- The universal release workflow targets macOS 12 Monterey for x86_64 and
  macOS 26 Tahoe for arm64.
- Local builds use the Mac's active architecture because Homebrew packages are
  architecture-specific. Homebrew is discovered through `brew --prefix`, which
  supports the usual `/opt/homebrew` Apple Silicon and `/usr/local` Intel
  installations.
- The release workflow builds a native x86_64 app first, transfers it through
  the Actions cache, and then builds the arm64 app. The arm64 build keeps its
  version and resources, merges every matching Mach-O into a universal binary,
  retains thin dependency files needed by only one architecture, validates
  each architecture's complete `@rpath` dependency graph, records the minimum
  macOS version for each architecture, preserves that assembled metadata past
  Xcode's generated-plist step, and produces the only retained workflow
  artifact. The packaging target restores and re-signs the assembled plist
  before notarization so a universal app cannot inherit the arm64-only minimum
  as a bundle-wide requirement.

`RAWTHERAPEE_UNIVERSAL_COUNTERPART_APP` is reserved for this second-stage
arm64 build. It must point to a thin x86_64 `RawTherapee.app`. The four
RawTherapee executables must exist in both components and become universal.
The embedded source version and full Git build UUID must match. Plist version
fields may differ because older and newer Xcode releases process generated
plists at different points; the arm64 plist supplies the final app metadata.
Homebrew dependencies may differ between runner images: matching paths are
merged, architecture-specific paths are retained as thin files, and the merge
fails if a dependency required by either architecture is absent or has the
wrong slice.

## Developer ID distribution

Install a `Developer ID Application` certificate through
**Xcode > Settings > Accounts > Manage Certificates**. The project deliberately
uses the generic certificate type and derives the team and exact signer from
the built application, so it is not tied to one developer account.

Copy `LocalSigning.xcconfig.example` to `LocalSigning.xcconfig` and put your
Apple Developer Team ID there. The local file is ignored by source control;
the shared project contains no developer-specific Team ID or certificate name.

Store notarization credentials in the login keychain under the profile name
`RawTherapee5`. This prompts securely for an app-specific password:

```sh
xcrun notarytool store-credentials RawTherapee5 \
  --apple-id YOUR-APPLE-ID \
  --team-id YOUR-10-CHARACTER-TEAM-ID
```

To make a complete release, select the **RawTherapee Distribution** scheme and
use **Product > Build**. Its package target:

1. Builds a sandboxed, hardened, Developer ID-signed application.
2. Submits the application to Apple and staples its notarization ticket.
3. Builds the upstream-style fancy APFS DMG and signs, notarizes, and staples it.
4. Produces a ZIP containing the DMG, install readme, and signed command-line
   shim, then submits that ZIP for notarization.

The finished DMG and ZIP are written to the top-level `dist` directory. Building
the distribution scheme requires network access and may prompt for permission
for Xcode or `create-dmg` to control Finder while arranging the disk image.

The generated CMake project is located below the target's Derived Sources
directory in DerivedData. It contains the `rth`, `rth-cli`, `rtengine`,
`LibRaw`, and `install` Xcode targets generated from the upstream CMake graph.
