# VaultSSH

A native macOS SSH agent for keys stored in Bitwarden or a compatible self-hosted vault.
Approve SSH signatures without keeping the Bitwarden desktop app open.

- Approve once or for five minutes, inspect caller processes, and revoke approvals.
- Choose the order in which this Mac offers keys; search activity and failures.
- English and Simplified Chinese, following your macOS app language.

## Install

Requires macOS 14+. Build with Xcode 27+ (macOS 27 SDK) and the Go version in
[`agent/go.mod`](agent/go.mod):

```sh
./scripts/build.sh
```

Quit VaultSSH, copy `dist/VaultSSH.app` to Applications, then reopen it. Local
builds and CI drafts are ad-hoc signed, **not notarized**. Automated builds cover
Apple Silicon; Intel and older macOS runtime compatibility need separate testing.
Liquid Glass is available on macOS 26+; native filter tabs require macOS 27.

## Connect

1. Install Bitwarden CLI (`bw` 2024.12.0+), or use **Install Compatible CLI** in the
   app. The installer needs Node.js/npm and installs CLI 2026.2.0 separately.
2. Run the app's copied login command in Terminal and complete two-factor login.
   For a self-hosted vault, configure the same CLI's server URL before logging in.
3. Enter your master password in VaultSSH, then open **Connect SSH** for setup.

For SSH, add this to `~/.ssh/config`, replacing any existing `IdentityAgent` entry:

```sshconfig
Host *
  IdentityAgent "~/Library/Application Support/VaultSSH/agent.sock"
```

For clients using `SSH_AUTH_SOCK`:

```sh
export SSH_AUTH_SOCK="$HOME/Library/Application Support/VaultSSH/agent.sock"
ssh-add -l
```

Use **… → Use First** on a key to prioritize it. Other keys remain available;
see [host-specific keys and troubleshooting](docs/troubleshooting.md).
Change language in **System Settings → General → Language & Region → Applications**.

## Security

Keys live in helper memory. The CLI session is stored in Keychain and can decrypt
the entire vault. Locking stops signing and deletes the saved session; quitting
stops the agent but retains the session. Lock explicitly when leaving your Mac.
Temporary approvals identify local executable paths and keys, not remote hosts.
Passphrase-protected private keys are not supported. No independent security
audit has been performed. Read the [security policy and limitations](SECURITY.md).

## Contribute

Run `./scripts/check.sh` for tests, a verified app build, and disposable-key
OpenSSH integration checks. See [Contributing](CONTRIBUTING.md),
[Releasing](docs/releasing.md), and the [Changelog](CHANGELOG.md).

[MIT licensed](LICENSE). [Third-party notices](THIRD_PARTY_NOTICES.md).
Independent project; not affiliated with Bitwarden.
