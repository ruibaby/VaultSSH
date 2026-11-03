# Changelog

## [Unreleased]

### Added

- Optional memory-only PIN unlock (6–12 digits), with a five-attempt limit.
- A keyless locked listener and compact on-demand unlock panel, followed by
  separate signature approval; cancellation and timeout reject pending requests.
- Optional system-authenticated Keychain quick unlock for appropriately signed
  builds; ad-hoc builds show it as unavailable.
- Configurable idle locking, off by default; sleep and screen-lock handling remain.

- MIT license, contribution guide, security policy and troubleshooting guide.
- macOS CI for tests, race detection, OpenSSH integration and bundle validation.
- Versioned ZIP packaging, checksums and a manually triggered draft-release workflow.
- Developer ID signing and notarization support for local release builds.
- Version/build information and project support links in Settings.

### Security

- Pass CLI passwords/sessions through stdin to an in-process Node adapter; reject
  unsupported CLI distributions and prevent credential-bearing subprocesses.
- Keep sessions in memory by default, remove legacy unprotected Keychain sessions,
  and clear loaded keys on sleep, observed screen lock, user switch or configured
  idle lock. Restarts require a fresh unlock; protected Keychain storage is opt-in.
- Bound SSH connections and partial-frame/write time, and survive descriptor exhaustion.
- Make Allow Once the primary action; prohibit cached grants for unknown callers
  and recognized script interpreters, including their parent processes.
- Lock npm runtime dependencies, add compatibility checks and a security release
  gate. Known upstream CLI advisories remain unresolved and block release.

### Fixed

- Rotate activity logs while running instead of only on startup.
- Keep the current session when saving an unchanged CLI path.
- Verify bundled helper signatures, architectures, licenses and translations.

### Initial capabilities

- Load SSH keys from Bitwarden CLI and compatible self-hosted vaults.
- Approve or deny signatures, inspect caller processes and revoke temporary approvals.
- Persist key order per Mac, inspect activity and configure SSH connections.
- Native macOS UI with English and Simplified Chinese translations.
