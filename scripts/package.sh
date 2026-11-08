#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/VaultSSH.app"
PROFILE="${NOTARY_PROFILE:-}"
IDENTITY="${SIGNING_IDENTITY:--}"
if [[ -n "$PROFILE" && "$IDENTITY" == "-" ]] || [[ -z "$PROFILE" && "$IDENTITY" != "-" ]]; then
  echo "Distribution packaging requires both SIGNING_IDENTITY and NOTARY_PROFILE. Omit both for ad-hoc testing." >&2
  exit 1
fi
"$ROOT/scripts/build.sh"
TEMP="$(mktemp -d "$ROOT/dist/.package.XXXXXX")"
MOUNT="$TEMP/mounted"
MOUNTED=false
cleanup() {
  if [[ "$MOUNTED" == true ]]; then
    hdiutil detach "$MOUNT" -quiet || { echo "Could not unmount $MOUNT; leaving $TEMP for cleanup." >&2; return; }
  fi
  rm -rf "$TEMP"
}
trap cleanup EXIT

notarize() {
  local artifact="$1"
  local credentials=(--keychain-profile "$PROFILE")
  if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then credentials+=(--keychain "$NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$artifact" "${credentials[@]}" --wait --timeout 30m \
    --output-format json > "$TEMP/notary-result.json"
  python3 - "$TEMP/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    sys.exit(f"Notarization failed: {result.get('status')}; submission {result.get('id')}. Use notarytool log to inspect it.")
PY
}

SUFFIX="-ad-hoc"
if [[ -n "$PROFILE" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/notarize.zip"
  notarize "$TEMP/notarize.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  SUFFIX=""
fi
"$ROOT/scripts/verify-app.sh" "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/VaultSSH" | tr ' ' '-')"
NAME="VaultSSH-$(cat "$ROOT/VERSION")-macos-$ARCH$SUFFIX"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/$NAME.zip"
# Check the extracted artifact, not only the build directory.
ditto -x -k "$TEMP/$NAME.zip" "$TEMP/extracted"
"$ROOT/scripts/verify-app.sh" "$TEMP/extracted/VaultSSH.app"

mkdir "$TEMP/dmg" "$MOUNT"
ditto "$APP" "$TEMP/dmg/VaultSSH.app"
ln -s /Applications "$TEMP/dmg/Applications"
hdiutil create -volname VaultSSH -fs HFS+ -srcfolder "$TEMP/dmg" -format UDZO "$TEMP/$NAME.dmg"
if [[ -n "$PROFILE" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$TEMP/$NAME.dmg"
  notarize "$TEMP/$NAME.dmg"
  xcrun stapler staple "$TEMP/$NAME.dmg"
  xcrun stapler validate "$TEMP/$NAME.dmg"
  codesign --verify --strict --verbose=2 "$TEMP/$NAME.dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TEMP/$NAME.dmg"
fi
hdiutil verify "$TEMP/$NAME.dmg"
MOUNTED=true
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$TEMP/$NAME.dmg"
test "$(readlink "$MOUNT/Applications")" = /Applications
"$ROOT/scripts/verify-app.sh" "$MOUNT/VaultSSH.app"
hdiutil detach "$MOUNT" -quiet
MOUNTED=false

# Publish local outputs only after both archives pass validation. Hash after stapling.
for extension in zip dmg; do
  mv "$TEMP/$NAME.$extension" "$ROOT/dist/$NAME.$extension"
  (cd "$ROOT/dist" && shasum -a 256 "$NAME.$extension" > "$NAME.$extension.sha256")
  echo "==> Packaged dist/$NAME.$extension"
done
