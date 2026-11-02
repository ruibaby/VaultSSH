#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/VaultSSH.app"
BUNDLE_ID="cc.ryanc.VaultSSH"

mkdir -p "$ROOT/.build"

echo "==> Building Go agent"
(
  cd "$ROOT/agent"
  CGO_ENABLED=1 CGO_CFLAGS="-mmacosx-version-min=14.0" CGO_LDFLAGS="-mmacosx-version-min=14.0" go build -buildvcs=false -trimpath -ldflags "-s -w" -o "$ROOT/.build/bwssh-agent" .
)

echo "==> Building Swift app"
(
  cd "$ROOT"
  # SwiftPM links with the deployment target as the SDK version, which makes
  # macOS treat the app as a legacy (pre-Liquid Glass) build. Record the real
  # SDK version so macOS 26+ picks the current appearance.
  # 14.0 must match the deployment target in Package.swift.
  SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
  swift build -c release --product VaultSSH \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
)
BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VaultSSH" "$APP/Contents/MacOS/VaultSSH"
cp "$ROOT/.build/bwssh-agent" "$APP/Contents/Resources/bwssh-agent"
ditto "$BIN_DIR/VaultSSH_VaultSSH.bundle" "$APP/Contents/Resources/VaultSSH_VaultSSH.bundle"
chmod +x "$APP/Contents/Resources/bwssh-agent"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
  cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> Done"
echo "$APP"
