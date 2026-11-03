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
the secure bridge.

For self-hosted vaults, configure the server on that same CLI before login.
Complete two-factor login in Terminal. Changing the custom path locks the app;
saving the same path only checks it again.

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
