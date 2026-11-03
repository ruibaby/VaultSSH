#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/VaultSSH.app"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Invalid VERSION: expected X.Y.Z" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "BUILD_NUMBER must be a positive integer (up to 9 digits)" >&2; exit 1; }
if [[ "$SIGNING_IDENTITY" != "-" && "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
  echo "Use '-' for local builds or a Developer ID Application identity for distribution." >&2
  exit 1
fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 27 ]] || { echo "Xcode 27+ with the macOS 27 SDK is required." >&2; exit 1; }

mkdir -p "$ROOT/.build" "$ROOT/dist"
echo "==> Building Go agent"
(
  cd "$ROOT/agent"
  CGO_ENABLED=1 CGO_CFLAGS="-mmacosx-version-min=14.0" CGO_LDFLAGS="-mmacosx-version-min=14.0" \
    go build -mod=readonly -buildvcs=false -trimpath -ldflags "-s -w" -o "$ROOT/.build/bwssh-agent" .
)

echo "==> Building Swift app"
(
  cd "$ROOT"
  # Record the actual SDK so macOS opts into the current system appearance.
  swift build -c release --product VaultSSH \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
)
BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"

# Assemble separately so a failed build cannot destroy the previous app.
STAGE="$(mktemp -d "$ROOT/dist/.build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/VaultSSH.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/VaultSSH" "$ROOT/.build/bwssh-agent" "$STAGED_APP/Contents/MacOS/"
ditto "$BIN_DIR/VaultSSH_VaultSSH.bundle" "$STAGED_APP/Contents/Resources/VaultSSH_VaultSSH.bundle"
cp "$ROOT/packaging/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$STAGED_APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
(
  cd "$ROOT/agent"
  cat "$ROOT/THIRD_PARTY_NOTICES.md"
  printf '\n--- Go runtime license ---\n'
  GO_ROOT="$(go env GOROOT)"
  GO_LICENSE="$GO_ROOT/LICENSE"
  # Homebrew places the distribution license one level above libexec.
  if [[ ! -f "$GO_LICENSE" ]]; then GO_LICENSE="$GO_ROOT/../LICENSE"; fi
  cat "$GO_LICENSE"
  for module in golang.org/x/crypto golang.org/x/sys; do
    printf '\n--- %s license ---\n' "$module"
    cat "$(go list -mod=readonly -m -f '{{.Dir}}' "$module")/LICENSE"
  done
) > "$STAGED_APP/Contents/Resources/ThirdPartyNotices.txt"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

SIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
# Sign nested executables first; never use --deep to sign.
codesign "${SIGN_FLAGS[@]}" "$STAGED_APP/Contents/MacOS/bwssh-agent"
codesign "${SIGN_FLAGS[@]}" "$STAGED_APP"
"$ROOT/scripts/verify-app.sh" "$STAGED_APP"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
echo "==> Built $APP ($VERSION, build $BUILD_NUMBER)"
