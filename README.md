# VaultSSH

A native macOS SSH agent for keys stored in Bitwarden or a compatible self-hosted vault.
Approve SSH signatures without keeping the Bitwarden desktop app open.

- Approve once or for five minutes, inspect caller processes, and revoke approvals.
- Choose the order in which this Mac offers keys; search activity and failures.
- English and Simplified Chinese, following your macOS app language.

## Why

I started using Bitwarden to keep my SSH private keys in a vault instead of
leaving plaintext key files on my local disk. But its built-in SSH agent's
approval experience kept interrupting my workflow: I couldn't tell which process
was requesting access, and each prompt brought the entire Bitwarden app to the
foreground.

I built VaultSSH to keep that vault-based setup with less disruption. A small,
non-activating approval panel shows the requesting process and its parent, so I
can make an informed decision without losing focus on what I'm doing.

## Install

Requires macOS 14+ and Node.js 22 with npm. Build with Xcode 27+ (macOS 27 SDK) and the Go version in
[`agent/go.mod`](agent/go.mod):

```sh
./scripts/build.sh
```

Quit VaultSSH, copy `dist/VaultSSH.app` to Applications, then reopen it. Local
builds and CI drafts are ad-hoc signed, **not notarized**. Automated builds cover
Apple Silicon; Intel and older macOS runtime compatibility need separate testing.
Liquid Glass is available on macOS 26+; native filter tabs require macOS 27.

## First-time setup

VaultSSH uses Bitwarden's command-line tool (`bw`) to access your vault. You
must log in to the CLI separately, even if the desktop app or browser extension
is already signed in. VaultSSH currently unlocks using your master password.

### 1. Install the CLI

Install [Node.js](https://nodejs.org/en/download) (which includes npm), then open
VaultSSH → **Settings → Install Compatible CLI… → Install**. This installs CLI
2026.10.1 in VaultSSH's own tools directory without replacing a system installation.

The installer uses a checked-in dependency lockfile. Secure access currently
supports only the **npm distribution of CLI 2026.10.1** with Node.js and the
security dependency versions in the bundled manifest. Use the in-app installer
to obtain this runtime, including when upgrading an older installation. A custom
npm installation must use the same manifest and lockfile; an ordinary global CLI
installation may not include the required dependency fixes.
Standalone binaries, other versions and unpatched runtimes are rejected; there is no fallback that
passes credentials in process arguments or startup environment variables.
Self-hosted server compatibility still needs testing with your server version.

In Terminal, set `BW` to the executable shown under **Settings → Current CLI**.
For the in-app installer, use:

```sh
BW="$HOME/Library/Application Support/VaultSSH/tools/node_modules/.bin/bw"
"$BW" --version
```

Run the remaining commands in this same Terminal window. Using this exact path
avoids accidentally configuring or logging in through another CLI installation.

### 2. Select your vault server

Before logging in, run **one** command for the server where your account lives:

| Account location | Command |
| --- | --- |
| Bitwarden US cloud | `"$BW" config server https://vault.bitwarden.com` |
| Bitwarden EU cloud | `"$BW" config server https://vault.bitwarden.eu` |
| Self-hosted | `"$BW" config server https://vault.example.com` (replace with your URL) |

If this CLI is already signed in to a different account or server, log out with
`"$BW" logout` before switching.

### 3. Log in in Terminal

```sh
"$BW" login
"$BW" status
```

Follow the prompts for your email, master password and two-step login if enabled.
A status of `locked` means login succeeded and the vault still needs unlocking;
`unauthenticated` means you are not signed in. Check that the reported account
and server are correct. See the [CLI login guide](https://bitwarden.com/help/cli/#log-in)
for supported authentication methods.

The CLI may print a session key and an `export BW_SESSION` command. You do not
need to copy or export it for VaultSSH; the app handles its own unlock session.

### 4. Unlock in VaultSSH

Return to VaultSSH, click **I've Signed In — Check Again**, then enter your master
password to unlock. Your keys must be saved as **SSH key** items in the vault;
keys stored in secure notes or attachments are not loaded. If needed, first
[create or import an SSH key in Bitwarden](https://bitwarden.com/help/about-ssh/),
then use **Refresh Keys** in VaultSSH. The matching public key must also be
authorized on the remote host or service you want to access.

## Connect SSH

Open **Connect SSH** in VaultSSH for configuration and a connection check.

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

## Quick unlock

Unlocking loads keys from the CLI's local encrypted cache without waiting for a
server sync. Use **Refresh Keys** after adding, changing or deleting keys in your
vault. If the cache contains no usable SSH keys, VaultSSH syncs once and retries.


After unlocking, open **Settings → Quick Unlock & Locking** to enable an optional
6–12 digit PIN. Locked SSH requests open a small panel; the main window can stay
closed. Unlocking resumes the request but still requires separate signature
approval.

PIN setup is saved in the macOS login Keychain; the PIN itself and vault session
are not saved. After restarting or five incorrect attempts, unlock once with your
vault password to resume using the same PIN.
Idle locking is off by default and can be set to 5, 15, 30 or 60 minutes. Sleep,
observed screen lock and user switching still lock the keys.

**Touch ID or Mac Password** uses a system-authentication-protected Keychain item.
It requires a properly signed build with data-protection Keychain entitlements;
ad-hoc builds show it as unavailable. It never falls back to unprotected storage.

## Security

Private keys live in helper memory; the CLI session can decrypt the entire vault.
Locking terminates the key-bearing helper and starts a fresh, keyless listener.
PIN retains an encrypted session in app memory. Opting into system quick unlock
stores a protected session in Keychain. Every launch still starts locked; waking
never restores access. Quitting stops the listener and clears PIN access.
Temporary approvals identify local executable paths and keys, not remote hosts;
known interpreters and unknown callers require approval for each signature.
Passphrase-protected private keys are not supported. No independent security
audit has been performed. The managed CLI includes pinned dependency security
updates, and the security release gate blocks high-severity findings. Read the
[security policy and limitations](SECURITY.md).

## Contribute

Run `./scripts/check.sh` for tests, a verified app build, and disposable-key
OpenSSH integration checks. See [Contributing](CONTRIBUTING.md),
[Releasing](docs/releasing.md), and the [Changelog](CHANGELOG.md).

[MIT licensed](LICENSE). [Third-party notices](THIRD_PARTY_NOTICES.md).
Independent project; not affiliated with Bitwarden.
