# Releasing

## Version and release policy

`VERSION` is the single source for the app's `X.Y.Z` version. Use semantic
versioning; before 1.0, minor versions may change behavior. `BUILD_NUMBER` is a
positive integer, defaulting to 1 locally and the workflow run number in CI.
`packaging/Info.plist` is a template populated by the build script.

Automated builds currently target Apple Silicon. macOS 14 is the deployment
minimum; CI on macOS 27 does not prove compatibility with every supported OS.
Test the oldest supported OS before making a compatibility claim for a release.
Intel builds are not covered by CI and should not be advertised as validated.

## Release without Apple credentials (default)

The release workflow defaults to **ad-hoc signing without notarization**. No
Apple Developer membership, Apple secrets or personal GitHub token is required.
Leave the repository variable `RELEASE_SIGNING` unset, or set it to `ad-hoc`.
Packages include `-ad-hoc` in the filename and release notes clearly state that
Apple has not notarized them. macOS may block their first launch; the
[README installation instructions](../README.md#install) link to Apple's
per-app approval procedure. System quick unlock remains unavailable in these builds.

## Enable notarized releases later

An active Apple Developer Program membership is required for new notarization
submissions. To enable this mode, configure the credentials below, then set the
repository variable `RELEASE_SIGNING` to `notarized`. Invalid mode values fail
the workflow; notarized mode never falls back to ad-hoc packaging on failure.

Create a **Developer ID Application** certificate and export it together with
its private key from Keychain Access as a password-protected `.p12`. A `.cer`
alone, Apple Development certificate or Developer ID Installer certificate is
not sufficient.

In App Store Connect, open **Users and Access → Integrations → App Store Connect
API → Team Keys**, and create a team API key with **Developer** access or higher.
The Account Holder may first need to request API access. Download its `.p8`
private key and record the Key ID and Issuer ID. This workflow uses a team key;
individual API keys use a different authentication flow.

In the repository's **Settings → Secrets and variables → Actions**, add these
repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `.p12`, including the private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_API_KEY_P8` | Entire `.p8` file, including PEM headers and newlines |
| `APPLE_API_KEY_ID` | App Store Connect team API Key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect team API Issuer ID |

Copy the encoded certificate to the clipboard without printing it:

```sh
base64 -i VaultSSH-DeveloperID.p12 | pbcopy
```

Under **Variables**, add `APPLE_SIGNING_IDENTITY`, with the exact certificate
name, for example `Developer ID Application: Your Name (TEAMID)`. Find it using:

```sh
security find-identity -v -p codesigning
```

No personal GitHub token or Apple ID password is needed. The workflow creates a
temporary Keychain with a random password, imports the certificate and stores
the notarization credentials there, then removes the Keychain and private files
even if packaging fails. Signing credentials are only used by the release
workflow, not pull-request checks.

This does not configure a provisioning profile or data-protection Keychain
entitlements for system quick unlock; that separate capability still needs the
provisioned-build validation described below.

References: [GitHub signing setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Apple API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api),
and [Apple's notarization action credential guidance](https://github.com/Apple-Actions/notarize).

## Prepare a version

1. Update `VERSION`, move the relevant Unreleased entries to a dated
   `## [X.Y.Z] - YYYY-MM-DD` heading in `CHANGELOG.md`, and keep an Unreleased heading.
2. Run `./scripts/check.sh`, `./scripts/check-cli-runtime.sh` and
   `./scripts/security-check.sh`. Resolve security-gate failures before release.
   Check English and Chinese UI, real CLI unlock,
   approval, deny, revocation, key order, sleep, screen lock, 15-minute idle lock
   and relaunch with a disposable test vault. Confirm waking stays locked.
   Verify PIN setup, restart requiring a master password, reuse of the original
   PIN after master unlock, five-attempt lockout, account changes, Keychain access
   denial, disable/delete, closed-window prompts and separate signature approval.
   Run `VAULTSSH_PIN_KEYCHAIN_TEST=1 swift test --filter PINKeychainTests` locally
   for a disposable login-Keychain round trip. For system quick unlock, test a signed and
   provisioned build with data-protection Keychain entitlements: verify both
   Touch ID and Mac-password fallback, denial/cancellation, and upgrade access.
   Ad-hoc CI builds cannot validate this path and must show it as unavailable.
   Automated CLI smoke tests cover an unauthenticated account, not real vault
   decryption or every self-hosted server version.
3. Review the diff and CI result. Commit the release preparation, create an
   annotated `vX.Y.Z` tag at that commit, then push the commit and tag.
4. Pushing the tag automatically starts **Release**. It checks the
   tag/version/changelog, reruns checks, builds packages in the selected mode,
   verifies both packages, uploads assets to a draft, then publishes it.
   **A successful run creates a public release automatically.** Review the notes
   and complete manual distribution testing before pushing the tag.

For example, after committing and pushing the release preparation:

```sh
git tag -a v0.1.0 -m 'Release v0.1.0'
git push origin v0.1.0
```

The tag must contain this workflow and the corresponding dated changelog entry;
an Unreleased section alone does not pass the release gate. Outputs are
`VaultSSH-X.Y.Z-macos-arm64-ad-hoc.dmg`, `.zip` and a `.sha256` sidecar for each
by default. Notarized releases omit `-ad-hoc`. In notarized mode, missing signing
credentials fail the job. Each notarization submission waits for up to 30 minutes;
a timeout fails the workflow even though Apple may continue processing it.

Retry a failed run, or manually run **Release** on `main` with an existing tag.
The manual workflow checks out the tag, not the latest `main` source. Reruns do
not overwrite an existing release. If a failed upload leaves a draft, explicitly
remove that unwanted draft while keeping the tag before retrying. Use a new
version for changes to an already published release.

## Developer ID distribution

For a normal downloadable app, use a Mac with a **Developer ID Application**
certificate and private key. Apple Development certificates are not substitutes.
Store notarization credentials in a local Keychain profile using `notarytool
store-credentials`; never commit them or put them in issue/CI logs.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='vaultssh-notary' BUILD_NUMBER=1 ./scripts/package.sh
```

The script signs the helper before the app, enables hardened runtime, submits
with `notarytool`, requires Accepted status, staples the app, checks Gatekeeper,
and then packages a ZIP and compressed HFS+ DMG with an Applications shortcut.
It separately signs, notarizes and staples the DMG, checks the mounted app,
and generates checksums after stapling. Set `NOTARY_KEYCHAIN` when the profile
is in a custom Keychain. There are no added exception entitlements.
See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Omit both `SIGNING_IDENTITY` and `NOTARY_PROFILE` for local ad-hoc packages;
these carry an explicit `-ad-hoc` filename and are not notarized.

Before tagging, test packages in the selected mode on another Mac with Gatekeeper
enabled. For ad-hoc builds, verify the documented per-app approval flow; for
notarized builds, verify normal first launch. Verify checksums, legacy Keychain cleanup and SSH
approval. Test an upgrade from the previous release: it must start locked and
require a fresh unlock. After publication, repeat the install smoke test using
a browser-downloaded release asset. Retain the previous release for rollback.
No in-app updater is implemented; users quit the app and replace it in Applications.

## Before making the repository public

- Confirm source/history contain no vault data, credentials or private fixtures.
- Review `SECURITY.md` links. Immediately after changing visibility to public,
  enable GitHub private vulnerability reporting before announcing the project;
  GitHub does not offer this feature for private repositories.
- Set branch protection for `main`, requiring the **macOS checks** CI job. If
  the account plan does not support protection for private repositories, configure
  it immediately after making the repository public and before accepting changes.
- Check the MIT license, bundled third-party notices and contribution templates.
- Set the repository description and topics; publish only sanitized screenshots.

Repository visibility and release publication are separate, deliberate actions.
