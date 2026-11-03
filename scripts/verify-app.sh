#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/VaultSSH.app}"
python3 - "$APP" "$(cat "$ROOT/VERSION")" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1])
contents = app / "Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "cc.ryanc.VaultSSH"
assert info["CFBundleShortVersionString"] == sys.argv[2], "Bundle version differs from VERSION"
assert info["CFBundleVersion"].isdigit() and int(info["CFBundleVersion"]) > 0
assert info["LSMinimumSystemVersion"] == "14.0"
architectures = []
for executable in ("VaultSSH", "bwssh-agent"):
    binary = contents / "MacOS" / executable
    assert binary.is_file() and binary.stat().st_mode & 0o111, f"Missing executable: {executable}"
    architectures.append(set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()))
assert architectures[0] == architectures[1], "App/helper architectures differ"
resources = contents / "Resources"
for filename in ("AppIcon.icns", "LICENSE.txt", "ThirdPartyNotices.txt"):
    assert (resources / filename).stat().st_size > 0, f"Missing resource: {filename}"
for language in ("en", "zh-Hans"):
    assert list((resources / "VaultSSH_VaultSSH.bundle").rglob(f"{language}.lproj/Localizable.strings")), f"Missing {language} translations"
for filename in ("bridge.cjs", "package.json", "package-lock.json"):
    matches = list((resources / "VaultSSH_VaultSSH.bundle").rglob(f"CLI/{filename}"))
    assert len(matches) == 1 and matches[0].stat().st_size > 0, f"Missing CLI resource: {filename}"
print(f"Bundle verified: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), {', '.join(sorted(architectures[0]))}")
PY
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/bwssh-agent"
codesign --verify --deep --strict --verbose=2 "$APP"
