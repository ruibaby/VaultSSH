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
4. From GitHub Actions, run **Release draft** on `main`, entering that exact tag.
   The workflow checks the tag/version/changelog, reruns checks and packages the
   app. It creates a **draft**, never an automatically published release.

The workflow produces an **ad-hoc signed, unnotarized** ZIP for testing, with an
explicit `-ad-hoc` filename and a SHA-256 sidecar. It needs no signing secrets.
Do not describe this artifact as a normal Gatekeeper-approved installation.
Review the draft and its notes before any publication. Reruns do not overwrite
an existing release; remove an unwanted draft explicitly before retrying.

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
and then packages and verifies an extracted copy. There are no added exception
entitlements. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Upload the resulting ZIP and `.sha256` to the draft, remove the ad-hoc assets and
ad-hoc warning, and test a browser-downloaded copy on another Mac with Gatekeeper
enabled. Verify its checksum, first launch, legacy Keychain cleanup and SSH
approval. Test an upgrade from the previous release: it must start locked and
require a fresh unlock.

Only then publish the release. Retain the previous release for rollback. No
in-app updater is implemented; users quit the app and replace it in Applications.

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
