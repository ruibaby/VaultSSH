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
- The session is stored in macOS Keychain and can decrypt the **whole vault**.
  Private keys are loaded into helper memory. VaultSSH does not intentionally
  persist plaintext private-key files, but does not guarantee memory zeroization.
- The app, helper, selected CLI and local account are trusted. Approval prompts
  do not protect against root, a compromised app/CLI, or arbitrary code running
  with equivalent access to the user's session and Keychain.
- Temporary approvals match executable path, parent executable path and key,
  for at most five minutes. They do not attest binary contents or restrict the
  remote destination. Agent forwarding obscures the remote caller behind local SSH.
- Locking cancels pending work, stops the helper and attempts to delete the saved
  session. Restore remains disabled if Keychain deletion fails. Quitting stops
  the helper but intentionally retains the session for the next launch.
- There is currently no automatic lock on sleep or screen lock. Lock explicitly
  when leaving the machine; remote-server vault locking does not immediately
  remove keys already loaded in helper memory.

## Local data and logs

`~/Library/Application Support/VaultSSH` contains the socket, status and local
activity logs. Activity includes process paths, key names and fingerprints;
these can reveal sensitive context even though signatures and private-key
material are not logged intentionally. CLI error output may contain account or
server information. Review and redact logs before sharing them.

The helper rotates activity logs at 5 MiB, retaining one previous file. The UI
keeps at most 500 events. No telemetry or automatic crash upload is implemented.

A valid code signature identifies a build's signer; Apple notarization checks
submitted software but is not a security audit of VaultSSH's design.
