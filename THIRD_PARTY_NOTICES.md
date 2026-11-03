# Third-party notices

VaultSSH is licensed under MIT. Its bundled Go helper includes:

- The [Go runtime](https://go.dev/LICENSE), under the Go BSD-style license.
- [golang.org/x/crypto](https://cs.opensource.google/go/x/crypto), under the Go BSD-style license.
- [golang.org/x/sys](https://cs.opensource.google/go/x/sys), under the Go BSD-style license.

Exact dependency versions are recorded in `agent/go.mod` and `agent/go.sum`.
The build script includes these licenses in the app at
`Contents/Resources/ThirdPartyNotices.txt`, alongside VaultSSH's MIT license.

Bitwarden CLI is installed separately, not bundled in the app. It retains its
own license and dependencies. VaultSSH is an independent project and is not
affiliated with or endorsed by Bitwarden.
