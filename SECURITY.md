# Security policy

VaultSSH is pre-1.0 software with no independent security audit. Only the latest
release is maintained; until the first release, fixes land on `main`.

## Report a vulnerability

Do not open a public issue with exploit details, vault contents or credentials.
Use [GitHub private vulnerability reporting](https://github.com/ruibaby/VaultSSH/security/advisories/new)
when it is available. If that form is unavailable, contact the maintainer through
[their GitHub profile](https://github.com/ruibaby) to arrange a private channel,
without sharing the exploit publicly. Private vulnerability reporting must be
enabled as soon as the repository becomes public, before announcing it; GitHub
only offers this feature for public repositories.

Include affected versions, a minimal reproduction using disposable keys,
expected and actual behavior, and the impact. There is no guaranteed response
time or bug-bounty program.

## Trust boundaries

- The app passes a Bitwarden CLI session to its child helper over inherited
  pipes. Approval decisions use the same private control channel, not files.
- Passwords and sessions enter the npm CLI over anonymous stdin pipes after
  Node starts. A bundled adapter loads the pinned CLI in that same process;
  secrets are not passed in OS startup arguments/environment. CLI subprocess
  creation is blocked as a compatibility guard, not as a sandbox.
- CLI sessions can decrypt the **whole vault**. By default they remain in memory;
  optional quick-unlock storage is described below. Private
  keys are loaded into helper memory. No plaintext private-key file is
  intentionally persisted; memory zeroization, swap and crash-dump exclusion
  are not guaranteed. The CLI manages its own encrypted vault cache on disk.
- Unlocking uses the CLI's local encrypted cache. Remote key changes or deletions
  take effect after a successful **Refresh Keys** sync, not on every unlock.
  A cache without usable SSH keys triggers one sync attempt. If a manual sync fails, cached
  keys remain usable and the app shows a warning; this is not a revocation check.
- The app, helper, Node runtime, selected npm CLI and local account are trusted.
  The adapter checks package layout, CLI version and required dependency versions, not the integrity of an already
  installed executable. Prompts do not protect against root, a compromised
  dependency, or arbitrary code with equivalent access to these processes.
- Temporary approvals match executable path, parent executable path and key,
  for at most five minutes. Unknown identities and recognized script runtimes
  (including parent runtimes) cannot cache grants. Runtime recognition uses
  executable names, not attestation: renamed runtimes and replaced binaries
  remain limitations. Approvals do not restrict remote destinations; agent
  forwarding obscures the remote caller behind local SSH.
- Locking invalidates pending work, revokes grants and terminates the key-bearing
  helper. A new keyless helper listens for SSH identity/sign requests and asks
  the app to unlock over the inherited pipe. Concurrent clients share one prompt;
  cancelling or exceeding 120 seconds denies the waiting requests. A ten-second
  cooldown limits immediate repeat prompts. Socket replacement has a brief gap;
  clients connecting during the transition may need to retry. Quitting stops it.
- The app always launches locked. Legacy unprotected Keychain sessions are
  deleted on startup; deletion failure never enables automatic restoration.
- The app locks on system/display sleep, user switching, an observed screen-lock
  notification, or a user-selected idle timeout (checked every five seconds).
  Idle locking is off by default; available timeouts are 5, 15, 30 and 60 minutes. Wake
  never unlocks. Screen-lock notification `com.apple.screenIsLocked` is an
  undocumented best-effort signal; public workspace notifications cover sleep
  and user switching, not every lock transition. Lock explicitly when needed.
  Remote-server vault locking does not immediately remove already loaded keys.
- The helper accepts at most 32 simultaneous SSH connections. Once a frame starts,
  it must arrive within five seconds; writes also have five-second deadlines.
  An idle connection with no partial frame may remain open for SSH compatibility.
  Same-user clients can still occupy all slots and deny service until disconnected;
  this bound prevents unbounded descriptor/goroutine growth, not all local DoS.

## Quick-unlock storage

PIN is opt-in while the vault is unlocked. A 6–12 digit PIN derives an AES-256-GCM
wrapping key using PBKDF2-HMAC-SHA256 (600,000 iterations) and a random 32-byte salt.
It protects a random key-agreement private key. The macOS login Keychain stores the
wrapped private key, public key, salt, format version and CLI/account/server
binding. It uses the creating app's default Keychain ACL and disables item sync;
it does not use the system-authenticated data-protection Keychain item below.
Ad-hoc app updates may require renewed Keychain access approval.

After a successful master-password unlock and key load, the saved public key
seals the fresh session using CryptoKit HPKE (Curve25519/SHA-256/ChaChaPoly).
Only this sealed session and the public encapsulated key remain in app memory
alongside the PIN-protected configuration. The PIN and wrapping key are not
persisted. Neither a plaintext nor an encrypted vault session is saved by PIN
setup; the saved configuration alone cannot restore a vault session on launch.
Correct PIN entry unwraps the private key and opens the in-memory session.

Five incorrect attempts discard the sealed session. A fresh master-password
unlock re-enables the same PIN; quitting discards session ciphertext but retains
PIN setup. Disabling PIN deletes its Keychain record. The attempt counter is an
**application policy, not a hardware-enforced limit**. Stolen PIN material permits
offline PIN guessing; a captured session ciphertext is also needed to recover
that session. Memory zeroization is not guaranteed. PIN does not protect against
a debugger or compromised local account.

System quick unlock is a separate opt-in. It stores the session in the macOS
data-protection Keychain with `WhenUnlockedThisDeviceOnly` and `userPresence`.
Every read uses a fresh authentication context (Touch ID or the Mac login
password); locking/cancelling invalidates the context. Unsupported signing or
Keychain access fails closed, with no legacy unprotected fallback. Ad-hoc builds
cannot enable this feature. A trusted signature, matching app identity and
Keychain entitlements/provisioning must be supplied for distribution.

Saved sessions are bound to the resolved CLI path, account email and server;
these are checked again before quick unlock. Changing accounts/CLI paths clears
quick-unlock options. Vault passwords are never persisted. A stale session or
failed vault load requires a fresh vault-password unlock; neither PIN nor system
authentication bypasses signature approval.

The system quick-unlock opt-in also stores its CLI path, account email and server
in app preferences, without a session. Master-password unlock checks this binding
before refreshing the protected Keychain session. A different or unverifiable
account clears the opt-in. Older opt-ins without this binding must be enabled
again after a master-password unlock.

## Dependency and release checks

The npm CLI runtime is installed with `npm ci` from the bundled manifest and
lockfile. The lockfile pins transitive versions and registry integrity hashes;
Node and npm themselves are external trusted prerequisites. Installation may run
upstream lifecycle scripts. Updating the CLI requires bridge compatibility tests
and a real test-vault unlock/sync/sign check, not just changing a version number.

Run `./scripts/security-check.sh` for Go reachable-vulnerability scanning and npm
lockfile auditing. Scheduled CI reports new advisories, and the draft-release
workflow blocks on Go findings or npm high/critical findings. There are no
blanket suppressions or automated forced dependency upgrades.

The managed runtime uses CLI 2026.10.1 with explicit security overrides for
`inquirer` 8.2.7, `multer` 2.5.0 and `node-forge` 1.4.3 because the upstream CLI
still pins older versions. The Inquirer update removes the legacy
`external-editor`/`tmp` dependency chain. The bridge requires these same versions
for custom npm installations. Review these overrides when updating the CLI;
remove them when its own dependencies include the fixes.

On 2026-11-07, the regenerated lockfile reported zero npm audit findings, and Go
scanning reported no reachable vulnerabilities. These results are a dated
snapshot, not a guarantee against later advisories. Compatibility checks cover
the installed runtime's startup and unauthenticated commands; a disposable real
vault is still required to validate unlock, sync and signing before release.

## Local data and logs

`~/Library/Application Support/VaultSSH` contains the socket, status and local
activity logs. Activity includes process paths, key names and fingerprints;
these can reveal sensitive context even though signatures and private-key
material are not logged intentionally. Credential-bearing CLI diagnostics are
replaced with fixed errors. Installer output and local activity can still reveal
account paths or other context; review and redact logs before sharing them.

The helper rotates activity logs at 5 MiB, retaining one previous file. The UI
keeps at most 500 events. No telemetry or automatic crash upload is implemented.

A valid code signature identifies a build's signer; Apple notarization checks
submitted software but is not a security audit of VaultSSH's design.
