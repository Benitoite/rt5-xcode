# GitHub Actions release signing and notarization

The `Signed and notarized distribution` workflow builds RawTherapee on
GitHub's Apple Silicon `macos-latest` runner. It imports a Developer ID
Application identity into a temporary keychain, creates a temporary
`notarytool` profile, builds the `RawTherapee Distribution` scheme, and directly
uploads one notarized ZIP as the workflow artifact.

`macos-latest` is a moving label. The workflow verifies that its selected Xcode
installation supplies at least the macOS 26 SDK required by this project and
stops with a clear error if GitHub changes the label incompatibly.

The workflow runs manually with **Actions > Signed and notarized distribution >
Run workflow**, and automatically for tags whose names start with `v`.

## 1. Export the Developer ID Application identity

The exported file must contain the certificate and its private key.

1. Open **Xcode > Settings > Accounts**.
2. Select the Apple Account and developer team.
3. Click **Manage Certificates**.
4. Control-click the active **Developer ID Application** certificate and choose
   **Export Certificate**.
5. Save it as a `.p12` file.
6. Protect the export with a strong, unique password. This password becomes the
   `APPLE_CERTIFICATE_PASSWORD` secret.

If Xcode cannot export the identity, open Keychain Access, select **login > My
Certificates**, expand the Developer ID Application certificate, and confirm
that a private key appears below it. A certificate without its private key
cannot sign on the Actions runner.

Apple's certificate export instructions are at:
https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html

## 2. Create a dedicated app-specific password

Do not put the normal Apple Account password into GitHub.

1. Sign in at https://account.apple.com/.
2. Open **Sign-In and Security > App-Specific Passwords**.
3. Generate a password named something recognizable, such as
   `GitHub Actions rt5-xcode`.
4. Copy the generated password. It becomes the
   `APPLE_APP_SPECIFIC_PASSWORD` secret.

Apple documents app-specific passwords at:
https://support.apple.com/en-us/102654

The local `RawTherapee5` Keychain profile is not exported or uploaded. The
workflow reconstructs an equivalent profile in its temporary keychain using
the Apple Account, app-specific password, and Team ID on every run.

## 3. Create the protected GitHub environment

In the `benitoite/rt5-xcode` repository:

1. Open **Settings > Environments**.
2. Choose **New environment**.
3. Name it exactly `release`.
4. If desired, add a required reviewer and restrict deployments to protected
   tags or branches.
5. Add the five environment secrets listed below.

Environment secrets are released only to jobs that reference that environment.
If the environment has a required reviewer, the secrets remain unavailable
until the run is approved.

GitHub's environment and secret documentation:

- https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments
- https://docs.github.com/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets

## 4. Add the five Actions secrets

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 text representing the exported `.p12` file |
| `APPLE_CERTIFICATE_PASSWORD` | The password chosen while exporting the `.p12` |
| `APPLE_ID` | The Apple Account email used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | The dedicated app-specific password |
| `APPLE_TEAM_ID` | The 10-character Team ID belonging to the Developer ID certificate |

The Team ID is visible in the certificate name and in the Apple Developer
membership details. Do not use the bundle ID in this field.

### Add secrets through the GitHub web interface

For the certificate secret, convert the binary `.p12` to one line of Base64
text and copy it to the clipboard:

```sh
/usr/bin/openssl base64 -A \
  -in "$HOME/Desktop/DeveloperIDApplication.p12" |
  pbcopy
```

In the `release` environment, click **Add secret**, name it
`APPLE_CERTIFICATE_P12_BASE64`, and paste the clipboard contents. Add the four
text secrets in the same place.

Base64 is only an encoding; it is not encryption. Treat the encoded certificate
as sensitive signing material. GitHub encrypts Actions secrets and does not
allow their values to be read back through the interface.

### Add secrets with GitHub CLI

Authenticate first:

```sh
gh auth login
```

Upload the certificate without placing it on the command line:

```sh
/usr/bin/openssl base64 -A \
  -in "$HOME/Desktop/DeveloperIDApplication.p12" |
  gh secret set APPLE_CERTIFICATE_P12_BASE64 \
    --env release \
    --repo benitoite/rt5-xcode
```

Run each command below and paste the requested value at its secure prompt:

```sh
gh secret set APPLE_CERTIFICATE_PASSWORD \
  --env release --repo benitoite/rt5-xcode

gh secret set APPLE_ID \
  --env release --repo benitoite/rt5-xcode

gh secret set APPLE_APP_SPECIFIC_PASSWORD \
  --env release --repo benitoite/rt5-xcode

gh secret set APPLE_TEAM_ID \
  --env release --repo benitoite/rt5-xcode
```

Confirm that all five names exist:

```sh
gh secret list --env release --repo benitoite/rt5-xcode
```

GitHub CLI encrypts secret values locally before uploading them:
https://cli.github.com/manual/gh_secret_set

## 5. Run the release workflow

Commit and push `.github/workflows/release-distribution.yml`, then use one of
these methods.

Manual run:

1. Open the repository's **Actions** tab.
2. Select **Signed and notarized distribution**.
3. Choose **Run workflow**.
4. Approve the `release` environment if it has a required reviewer.

Tagged release build:

```sh
git tag v5.13-xcode1
git push origin v5.13-xcode1
```

The build can take a long time because RawTherapee and its Homebrew dependency
stack are compiled and bundled on a fresh runner. Apple notarization is
performed three times: for the app, DMG, and final ZIP.

After success, open the workflow run and download the artifact named after the
packaged ZIP:

```text
RawTherapee_MacOS_<minimum-macOS>_<architecture>_<RawTherapee-version>.zip
```

For example, an Apple Silicon build may be named:

```text
RawTherapee_MacOS_26.0_arm64_5.13-rc1-34-g71c625fe7.zip
```

The ZIP contains exactly four files at its root:

- `install-readme.rtf`
- The signed, notarized, and stapled `.dmg`
- `rawtherapee-cli`
- `About-this-build.txt`, containing the source commits, runner and toolchain
  versions, workflow URL, and component SHA-256 checksums

The standalone DMG is not uploaded separately.
Actions uses direct-file artifact upload, so GitHub does not wrap this ZIP in
another ZIP layer.

The workflow artifact is retained for 30 days. It does not automatically create
a GitHub Release or attach files to one.

## Security and maintenance

- Never commit the `.p12`, its Base64 representation, the app-specific
  password, or `LocalSigning.xcconfig`.
- Keep the original encrypted `.p12` in protected offline storage, or securely
  remove it after confirming the Actions secret works.
- Pin Actions dependencies to reviewed commit hashes. The workflow currently
  pins GitHub's official checkout and artifact actions.
- Do not enable this signing job for pull requests. Untrusted code must never
  run with release credentials.
- Revoke and replace the Developer ID certificate immediately if its private
  key or export password may have been exposed.
- Revoke the dedicated app-specific password at account.apple.com when the
  workflow is retired, and replace the secret whenever Apple revokes it.
- Certificate expiration or renewal requires exporting the new identity and
  replacing both certificate secrets.
