<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/RawTherapee/RawTherapee/dev/rtdata/images/rt-logo-text-white.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/RawTherapee/RawTherapee/dev/rtdata/images/rt-logo-text-black.svg">
  <img alt="RawTherapee logo" src="[https://user-images.githubusercontent.com/25423296/163456779-a8556205-d0a5-45e2-ac17-42d089e3c3f8.png](https://raw.githubusercontent.com/RawTherapee/RawTherapee/dev/rtdata/images/rt-logo-text-black.svg)">
</picture>

# *How to build RawTherapee 5.13+ on Apple® Xcode®*

There are 3 methods for building RawTherapee on Apple® Xcode®:

* Build for yourself
* Build for distribution
* Build a universal distribution on two Macs

# Method 1: Ad Hoc build for your own machine.

## Prepare the build environment:
```zsh
git clone https://github.com/benitoite/rt5-xcode.git && \
cd rt5-xcode && \
git submodule update --init --recursive 
```
### Or, if you want to build from `dev` use the `follow-dev` branch:
```zsh
git clone https://github.com/benitoite/rt5-xcode.git && \
cd rt5-xcode && \
git switch follow-dev && \
git pull --ff-only && \
git submodule update --init --recursive
```

## Ad-hoc build to run on your local machine:

```zsh
xcodebuild \
  -project RawTherapee5.xcodeproj \
  -scheme RawTherapee \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  build
```

### You will fnd the built application in:
```zsh
DerivedData/Build/Products/Release
```

### run the built application immediately:
```zsh
open DerivedData/Build/Products/Release/RawTherapee.app
```

### Install the built application:
```zsh
sudo /usr/bin/ditto \
  "$PWD/DerivedData/Build/Products/Release/RawTherapee.app" \
  "/Applications/RawTherapee.app"
```

### Run the Installed application:
```zsh
open -a rawtherapee
```

# Method 2: Build for Distribution outside the App Store
Apple® Developers may also choose to build a distributable package using this method.

## Prepare the build environment [as above](https://github.com/Benitoite/rt5-xcode/blob/main/README.md#prepare-the-build-environment)

## Setup Notary Services
### Run this command with your details (you will be prompted for your Apple® App-Specific Password)
```zsh
xcrun notarytool store-credentials RawTherapee5 \
  --apple-id "YOUR-APPLE-ID-EMAIL" \
  --team-id YOUR-10-DIGIT-TEAM-ID
```

### Verify Notary credential:
```zsh
xcrun notarytool history --keychain-profile RawTherapee5
```

### Create the Local Signing File:
```zsh
cp XcodeSupport/LocalSigning.xcconfig.example \
   XcodeSupport/LocalSigning.xcconfig
```

### Edit the Local Signing File & insert your Apple® Developer Team ID value (a 10-digit code)
With an editor:
```zsh
pico XcodeSupport/LocalSigning.xcconfig
```
or with TextEdit:
```zsh
open -a textedit XcodeSupport/LocalSigning.xcconfig
```
or on the command line, replacing `YOUR-10-DIGIT-TEAM-ID` with your actual Team ID:
```zsh
sed 's/^RAWTHERAPEE_DEVELOPMENT_TEAM[[:space:]]*=.*/RAWTHERAPEE_DEVELOPMENT_TEAM = YOUR-10-DIGIT-TEAM-ID/' \
  XcodeSupport/LocalSigning.xcconfig.example \
  > XcodeSupport/LocalSigning.xcconfig
```

### Build RawTherapee distribution package: (The command may request permission for create-dmg to control Finder.)
```zsh
xcodebuild \
  -project RawTherapee5.xcodeproj \
  -scheme 'RawTherapee Distribution' \
  -configuration Distribution \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  build
```

### Find the distributable zip artifact in `rt5-xcode/dist`

### Test the built application directly:
```zsh
open DerivedData/Build/Products/Distribution/RawTherapee.app
```

### Install the built application for testing:
```zsh
sudo /usr/bin/ditto \
  "$PWD/DerivedData/Build/Products/Distribution/RawTherapee.app" \
  "/Applications/RawTherapee.app"
```

# Method 3: Build a universal distribution on two Macs

## Prepare the build environment [as above](https://github.com/Benitoite/rt5-xcode/blob/main/README.md#prepare-the-build-environment)

Use the same repository commit on both Macs. Only the arm64 Mac needs the
signing and notarization setup from Method 2.

## 1. On the Intel Mac

```zsh
./XcodeSupport/two-mac-universal.sh intel
```

Wait for the ZIP to finish syncing through iCloud Drive.

## 2. On the arm64 Mac

```zsh
./XcodeSupport/two-mac-universal.sh arm
```

The completed universal distribution ZIP will be in `dist`.
