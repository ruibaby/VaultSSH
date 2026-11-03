# Security policy

VaultSSH is pre-1.0 software with no independent security audit. Only the latest
release is maintained; until the first release, fixes land on `main`.

## Report a vulnerability

Do not open a public issue with exploit details, vault contents or credentials.
Use [GitHub private vulnerability reporting](https://github.com/ruibaby/VaultSSH/security/advisories/new)
when it is available. If that form is unavailable, contact the maintainer through
[their GitHub profile](https://github.com/ruibaby) to arrange a private channel,
without sharing the exploit publicly. Private vulnerability reporting must be
enabled before making this repository public.

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
- Sessions are held in memory only and can decrypt the **whole vault**. Private
  keys are loaded into helper memory. No plaintext private-key file is
  intentionally persisted; memory zeroization, swap and crash-dump exclusion
  are not guaranteed. The CLI manages its own encrypted vault cache on disk.
- The app, helper, Node runtime, selected npm CLI and local account are trusted.
  The adapter checks package layout/version, not the integrity of an already
  installed executable. Prompts do not protect against root, a compromised
  dependency, or arbitrary code with equivalent access to these processes.
- Temporary approvals match executable path, parent executable path and key,
  for at most five minutes. Unknown identities and recognized script runtimes
  (including parent runtimes) cannot cache grants. Runtime recognition uses
  executable names, not attestation: renamed runtimes and replaced binaries
  remain limitations. Approvals do not restrict remote destinations; agent
  forwarding obscures the remote caller behind local SSH.
- Locking invalidates pending work, revokes grants and stops the helper. Sessions
  are not restored after launch. Legacy Keychain sessions are deleted on startup;
  if deletion fails, restoration stays disabled and an error is shown.
- The app locks on system/display sleep, user switching, an observed screen-lock
  notification, or 15 minutes without input (checked every five seconds). Wake
  never unlocks. Screen-lock notification `com.apple.screenIsLocked` is an
  undocumented best-effort signal; public workspace notifications cover sleep
  and user switching, not every lock transition. Lock explicitly when needed.
  Remote-server vault locking does not immediately remove already loaded keys.
- The helper accepts at most 32 simultaneous SSH connections. Once a frame starts,
  it must arrive within five seconds; writes also have five-second deadlines.
  An idle connection with no partial frame may remain open for SSH compatibility.
  Same-user clients can still occupy all slots and deny service until disconnected;
  this bound prevents unbounded descriptor/goroutine growth, not all local DoS.

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

As of 2026-11-03, the pinned CLI dependency tree has high-severity advisories in
`form-data`, `koa`, `multer`, `node-forge` and `tmp` (npm also reports the parent
CLI as affected). Reachability through VaultSSH's selected commands has not been
established. These alerts are **unresolved and block release**, not a claim that
all of those vulnerabilities can be exploited through VaultSSH. Go scanning
reported no reachable vulnerabilities in the helper at the time of this review.

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
