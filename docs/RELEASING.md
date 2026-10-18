# GitHub release setup

WAMC distributes through `solvePao/wamc-releases` and mirrors the same APK, DMG, and metadata to the source repository’s Releases page. Apps continue checking `wamc-releases` for updates. Source is hosted in `solvePao/wamc`. The repository is public so GitHub branch protection is available on the current plan. No App Store or Play Store submission occurs.

## Apple credentials

1. In Xcode Settings → Apple Accounts → team → Manage Certificates, create a **Developer ID Application** certificate. Export the certificate and its private key as a password-protected `.p12`. Do not revoke an existing certificate merely because this Mac lacks its private key.
2. In Apple Developer Certificates, Identifiers & Profiles, select the existing `com.androidwebcam.app` identifier and enable **System Extension**. Create a **Developer ID** distribution profile for this identifier and the new certificate. Download its `.provisionprofile`. Use the same team as the current app and camera extension (`HU27CJ3DK6`). If the camera extension's capabilities require a profile, create its Developer ID profile for `com.androidwebcam.app.CameraExtension` too.
3. In App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys, create a key with Developer access for notarization. Record its Key ID and Issuer ID and download its `.p8` once. Notarization uses Apple infrastructure without creating a store listing.

References: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

## GitHub configuration

Create environment **release** in `solvePao/wamc`. Configure these environment secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the permanent Android release keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Signing key alias |
| `ANDROID_KEY_PASSWORD` | Signing key password |
| `MACOS_CERTIFICATE_BASE64` | Base64 of exported Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Export password |
| `MACOS_PROFILE_BASE64` | Base64 of Developer ID host `.provisionprofile` |
| `MACOS_EXTENSION_PROFILE_BASE64` | Optional base64 of extension distribution profile |
| `NOTARY_KEY_BASE64` | Base64 of App Store Connect `.p8` |
| `NOTARY_KEY_ID` | API Key ID |
| `NOTARY_ISSUER_ID` | API Issuer ID |
| `SPARKLE_PRIVATE_KEY` | Private EdDSA key exported by Sparkle `generate_keys` |
| `RELEASE_PUBLISH_TOKEN` | Fine-grained token restricted to `wamc-releases`, Contents read/write |

Configure these environment variables:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `HU27CJ3DK6` (confirm against your certificate) |
| `MACOS_SIGN_IDENTITY` | Full `Developer ID Application: … (HU27CJ3DK6)` identity |
| `SPARKLE_PUBLIC_KEY` | Public key printed by Sparkle `generate_keys` |
| `ANDROID_SIGNING_SHA256` | SHA-256 of permanent Android signing certificate, with or without colons |

Upload file contents without printing them. Example on macOS, adjusting only the path:

```sh
base64 -i /private/tmp/wamc-developer-id.p12 | gh secret set MACOS_CERTIFICATE_BASE64 --repo solvePao/wamc --env release
base64 -i /path/to/host.provisionprofile | gh secret set MACOS_PROFILE_BASE64 --repo solvePao/wamc --env release
base64 -i /path/to/AuthKey_KEYID.p8 | gh secret set NOTARY_KEY_BASE64 --repo solvePao/wamc --env release
gh secret set MACOS_CERTIFICATE_PASSWORD --repo solvePao/wamc --env release
```

The final command prompts for the password without placing it in command history. Keep encrypted backups of the Android keystore and Sparkle key: future updates require the same keys. Do not commit private keys or certificates.

## Version and release

1. Update `release.json`: increase both `version` and `build`. Initial updater release is `0.2.0`, build `4`.
2. Run `python3 scripts/testing/run_tests.py` locally and resolve any test or coverage failures. Both app gates require exact 100% production line coverage. Then run Build CI and review both platform builds; GitHub Actions does not execute tests.
3. Commit the validated version, tag it `v0.2.0` (matching the version file), and push that tag to the source repository.
4. Release CI signs the APK, signs and notarizes the Mac app and DMG, and signs the DMG for Sparkle.
5. After both builds succeed, publication creates a draft in the public binary repository, uploads paired artifacts and update metadata, verifies its asset set, then publishes it. A separate job copies the verified assets into a release on `solvePao/wamc`, using that repository’s built-in Actions token. If mirroring fails, rerun the failed mirror job.

Failed builds publish nothing. A retry can resume an unpublished draft. Published versions are immutable; fix and increase the version/build rather than overwriting them. Update metadata is attached to the same release as the binaries. Avoid publishing an incomplete release manually: both apps follow the latest stable release.

For failures, inspect jobs/logs with GitHub MCP, fix the source, and rerun. Build workflow supports manual dispatch for validation. The release workflow runs only from matching version tags. Never use development signing or skip notarization to force a public release through.

## Bootstrap and verification

Existing apps need one manual installation to gain updater support. Android debug installs may require uninstalling before installing the permanent release-signed APK, which removes saved settings. Later releases signed with the same key preserve data.

Both apps check once per launch and prompt before download. Manual checks remain available. Installations wait until streaming stops. Android requests native installation permission/approval; macOS may request permission for replacement or extension activation.

Validate an upgrade between two signed builds on a physical Android phone and Mac. Verify preserved settings, USB/Wi-Fi streams, camera extension readiness, checksum rejection, cancellation, and streaming deferral. Confirm public assets and feed are accessible anonymously.

## Configured publisher credential

The repository-restricted WAMC release publisher token expires on November 17, 2026. Rotate `RELEASE_PUBLISH_TOKEN` in the release environment before that date. Its scope is `solvePao/wamc-releases` only, Contents read/write plus required Metadata read-only.

## Main branch protection

`main` requires pull requests and successful GitHub Actions checks named `android` and `macos`. Branches must be up to date before merging, and review conversations must be resolved. Protection applies to administrators; force pushes and branch deletion are disabled. Independent review approval is optional so a solo maintainer can merge a passing pull request. Repository administrators can still change these settings.
