# Troubleshooting

## macOS blocks a downloaded build

A `-ad-hoc` artifact has no Developer ID notarization. Prefer a notarized release
or build from reviewed source. Do not disable Gatekeeper globally. CI artifacts
are for testing, not evidence of a notarized release.

## CLI missing or login fails

Open Settings and check the detected path/version. **Install Compatible CLI**
requires Node.js 22/npm and installs the pinned npm CLI inside VaultSSH's Application
Support directory. Use the exact **Copy Login Command** from the app: another
`bw` on your PATH may use a different account or configuration. Standalone CLI
binaries and versions other than the pinned npm release are not supported by
the secure bridge. Reinstall through **Install Compatible CLI** after upgrading
VaultSSH. Custom npm installations must use VaultSSH's manifest and lockfile,
including its dependency security updates; matching the CLI version alone is
not sufficient.

For self-hosted vaults, configure the server on that same CLI before login.
Complete two-factor login in Terminal. Changing the custom path locks the app;
saving the same path only checks it again.

## Quick unlock

Enable PIN in **Settings → Quick Unlock & Locking** after unlocking the vault.
Your PIN setup is saved in the macOS login Keychain. After restarting or five
incorrect attempts, unlock with your vault password once; the same PIN works
again. Disabling PIN removes its saved setup. A Keychain access error leaves PIN
unavailable; allow the app's Keychain request or disable PIN and set it again. The PIN does not replace your Bitwarden master password.

With the app running and CLI configured, an SSH request while locked opens a
small unlock panel, even when the main window is closed. Cancelling denies the
waiting requests and adds a short prompt cooldown. Retry a connection that
arrived during the brief helper restart when locking.

Touch ID/Mac-password quick unlock is unavailable in ad-hoc builds. It requires
an app signed and provisioned for the data-protection Keychain. Error `-34018`
means missing Keychain entitlements; do not work around it by storing the session
without authentication. PIN and vault-password unlock remain available.

System quick unlock is bound to the CLI path, account and server where it was
enabled. Switching accounts or being unable to confirm that binding clears the
opt-in before saving another session. Older opt-ins without a saved binding also
require a fresh master-password unlock and re-enabling the setting.

## SSH offers the wrong key

Use the key's **… → Use First** menu. Ordering affects future requests, and other
keys remain available. For one host that must use a specific key, save **only
its public key** to a file and configure:

```sshconfig
Host example-host
  HostName example.com
  IdentityAgent "~/Library/Application Support/VaultSSH/agent.sock"
  IdentityFile ~/.ssh/example-key.pub
  IdentitiesOnly yes
```

Inspect effective configuration with `ssh -G example-host`. Existing matching
SSH entries may take precedence. Do not export the private key for this setup.

## No agent or no approval prompt

Unlock VaultSSH, open **Connect SSH**, and run its connection check. For clients
that use the environment, set `SSH_AUTH_SOCK` as described in the README and run
`ssh-add -l`. An already-running terminal or IDE may still have another socket
path. The app must remain running, even when its main window is closed.

Approvals expire after 60 seconds. **Revoke Temporary Approvals** clears the
five-minute cache. Forwarded SSH requests identify the local forwarding process,
not the remote host; see the [security policy](../SECURITY.md).

## Upgrade or uninstall

Quit VaultSSH before replacing it in Applications. Reopen and verify a test SSH
connection. Every launch requires a fresh unlock; waking does not unlock.

To uninstall, lock VaultSSH first to stop signing, disable launch at
login in Settings, quit, and remove the app. You may then remove its Application
Support folder (including its separately installed CLI and local logs). Remove
VaultSSH-specific `IdentityAgent` / `SSH_AUTH_SOCK` settings from your shell and
SSH configuration. Do not remove unrelated SSH or Bitwarden configuration.

## Reporting a problem

Include the VaultSSH version/build, macOS version, chip architecture, CLI version,
installation source and minimal steps. Redact usernames, server URLs, process
paths and key names from diagnostics. Never attach a vault export, session,
master password or private key. Report security issues privately.

## Unlocking is slow or a changed key is missing

Unlocking verifies the vault password, checks the CLI account, then reads keys
from the local encrypted cache. The UI shows the current stage. Password key
derivation and CLI startup still take time; PIN skips the master-password step.

Use **Refresh Keys** after a remote key change. Normal unlock does not wait for a
network sync when cached SSH keys exist. A cache without usable SSH keys syncs once automatically;
manual refresh also syncs first. A failed sync can use cached keys with a warning,
so remote deletions are not applied until a sync succeeds.
