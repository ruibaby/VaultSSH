# Contributing

Small, focused pull requests are welcome. For larger changes, open an issue
first to agree on the user problem and scope. Follow the [security policy](SECURITY.md)
for vulnerabilities instead of opening a public issue.

## Local setup

Use macOS, Xcode 27+ with the macOS 27 SDK, Go as specified in `agent/go.mod`,
Node.js 22/npm, Python 3, and the system OpenSSH tools. Select Xcode with `xcode-select` before
building. CI currently uses Xcode 27.1 on an Apple Silicon runner.

```sh
./scripts/check.sh
```

Run `./scripts/check-cli-runtime.sh` to install the locked npm runtime in a
temporary directory and smoke-test it with an isolated, unauthenticated account.
Run `./scripts/security-check.sh` for dependency advisories; high-severity
CLI findings block release (see `SECURITY.md`). To update the runtime
lock, use npm to regenerate it; never hand-edit integrity hashes.

This checks shell syntax and Go formatting, runs Swift tests, Go vet and race
tests, builds and verifies the app, and exercises real OpenSSH signing with
**disposable keys**. No Bitwarden account, production key, or signing certificate
is needed. Build output lives in `.build/` and `dist/` and must not be committed.

## Project layout

- `Sources/VaultSSH`: SwiftUI app, CLI integration, Keychain and helper control.
- `agent`: Go SSH agent, key loading, approval protocol and audit events.
- `Tests` and `agent/*_test.go`: unit and concurrency tests.
- `scripts/test-agent.py`: OpenSSH integration and parent-disconnect checks.
- `packaging` and `scripts`: app resources, validation and distribution.

## Change expectations

- Keep approval decisions on the inherited pipes. Treat socket clients and
  process names as untrusted input; never authorize from files or logs.
- Add a regression test for behavior changes, particularly cancellation,
  session handling, parsing and approval timeouts.
- Use `gofmt` for Go. Follow the surrounding Swift style; avoid unrelated changes.
- Add user-facing text to both `en.lproj` and `zh-Hans.lproj`. Helper messages
  belong in `agent/localization.go`. Do not display protocol codes as UI text.
- Check changed screens in English and Chinese, light and dark appearance,
  and with keyboard navigation. Never commit screenshots of real vault data.
- Update `CHANGELOG.md` under Unreleased for user-visible changes.
- Never include credentials, session values, private keys or raw vault exports
  in issues, commits, fixtures or CI artifacts.

Pull requests should explain the problem, resulting behavior, and checks run.
Contributions are provided under the project's MIT license. Maintainers should
follow [Releasing](docs/releasing.md) when preparing a version.
