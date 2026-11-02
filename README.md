# VaultSSH

A native macOS SSH agent for keys stored in Bitwarden or a compatible self-hosted vault. Use your existing keys without keeping the Bitwarden desktop app open.

- Approve signatures in a non-activating panel with caller and parent-process details.
- Allow once or for five minutes, and revoke temporary approvals anytime.
- Choose the order in which this Mac offers your keys.
- Search activity and inspect failures.
- English and Simplified Chinese, following your macOS app language.

## Build and install

Requires macOS 14+, Xcode 27+ (macOS 27 SDK), and Go 1.27+. Liquid Glass is available on macOS 26+; native filter tabs require macOS 27.

```sh
./scripts/build.sh
```

Quit any running VaultSSH instance, then copy `dist/VaultSSH.app` to Applications. Local builds are ad-hoc signed and are not notarized.

## Connect your vault

1. Install Bitwarden CLI (`bw` 2024.12.0 or later), or use **Install Compatible CLI** in the app. The bundled installer requires Node.js and npm and installs CLI 2026.2.0 under the app's Application Support directory.
2. Copy the login command shown in VaultSSH and run it in Terminal. Complete any two-factor authentication there. For a self-hosted vault, configure that same CLI's server URL before logging in.
3. Enter your master password in VaultSSH to unlock your keys.
4. Open **Connect SSH**, or add this to `~/.ssh/config`, replacing any existing `IdentityAgent` entry:

```sshconfig
Host *
  IdentityAgent "~/Library/Application Support/VaultSSH/agent.sock"
```

For programs that use `SSH_AUTH_SOCK`, set it in their environment:

```sh
export SSH_AUTH_SOCK="$HOME/Library/Application Support/VaultSSH/agent.sock"
ssh-add -l
```

Use a key's **… → Use First / Move Up / Move Down** menu to change its priority. Order is saved locally and survives refreshes and restarts. Other keys remain available; host-specific SSH identity settings can override agent order.

To change the app language, use **System Settings → General → Language & Region → Applications**, then reopen VaultSSH.

## Security and limitations

- Private keys are loaded into helper memory; VaultSSH does not intentionally write plaintext private-key files. The CLI session is stored in macOS Keychain and can decrypt the entire vault.
- Locking stops signing and deletes the saved session. Quitting stops the agent. If the app disconnects or an approval times out, signing is denied.
- Temporary approval covers the same executable path, parent executable path, and key for up to five minutes. It is not restricted to a remote host. Forwarded requests appear as the local SSH process.
- Passphrase-protected private keys and in-app two-factor login are not supported. CLI/server compatibility varies; the pinned installer version is a compatibility choice, not a guarantee for every server release.
- No independent security audit has been performed. Local approval checks do not isolate keys from root or a compromised app/CLI.

## Development

```sh
swift test
(cd agent && go test -race -buildvcs=false ./...)
python3 scripts/test-agent.py .build/bwssh-agent
```

UI translations live in `Sources/VaultSSH/Resources/*.lproj`; helper diagnostics live in `agent/localization.go`. Existing log details and external CLI output retain their original language.
