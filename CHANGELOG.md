# Changelog

## [Unreleased]

## [0.1.0] - 2026-11-08

The first release of VaultSSH, a native macOS SSH agent for keys stored in Bitwarden.

Requires macOS 14+, Node.js 22 and npm. This release provides Apple Silicon builds; Intel and older macOS runtime compatibility have not been separately validated. System-authenticated quick unlock is unavailable in this build.

### Features

- Load SSH keys from Bitwarden or a compatible self-hosted vault without keeping the Bitwarden desktop app running.
- Approve signatures once or for five minutes, inspect the requesting process and its parent, and revoke approvals at any time.
- Unlock on demand when an SSH request arrives, with optional PIN unlock. A master-password unlock is still required after restarting the app.
- Customize key order, browse activity, and use the app in English or Simplified Chinese.
- Install using a drag-and-drop DMG, or download a ZIP, with SHA-256 checksums for both.

### Improvements

- Load cached SSH keys before attempting network sync during unlock to reduce waiting time.
- Clear loaded keys on sleep, detected screen lock, user switching, or the configured idle timeout.

### Dependencies

- Use Bitwarden CLI 2026.10.1 with pinned security dependency fixes. Install the compatible CLI from the app's settings.
