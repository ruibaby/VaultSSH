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
trap 'rm -rf "$TEMP"' EXIT
SUFFIX="-ad-hoc"
if [[ -n "$PROFILE" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/notarize.zip"
  xcrun notarytool submit "$TEMP/notarize.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$TEMP/notary-result.json"
  python3 - "$TEMP/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    sys.exit(f"Notarization failed: {result.get('status')}; submission {result.get('id')}. Use notarytool log to inspect it.")
PY
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  SUFFIX=""
fi
"$ROOT/scripts/verify-app.sh" "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/VaultSSH" | tr ' ' '-')"
NAME="VaultSSH-$(cat "$ROOT/VERSION")-macos-$ARCH$SUFFIX.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/$NAME"
# Check the extracted artifact, not only the build directory.
ditto -x -k "$TEMP/$NAME" "$TEMP/extracted"
"$ROOT/scripts/verify-app.sh" "$TEMP/extracted/VaultSSH.app"
mv "$TEMP/$NAME" "$ROOT/dist/$NAME"
(cd "$ROOT/dist" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "==> Packaged dist/$NAME"
