#!/usr/bin/env python3
"""Exercise distribution failure barriers without certificates or Apple requests."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOLS = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
root = pathlib.Path(os.environ["PACKAGE_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "lipo":
    print("arm64")
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        rejected = args[2].endswith(os.environ.get("REJECT_EXTENSION", "never"))
        print(json.dumps({"status": "Invalid" if rejected else "Accepted", "id": "test-submission"}))
    elif args[:2] == ["stapler", "staple"] and args[2].endswith(".dmg"):
        with open(args[2], "ab") as image:
            image.write(b"stapled-ticket")
elif name == "hdiutil":
    if args[0] == "create":
        pathlib.Path(args[-1]).write_bytes(b"test-image")
    elif args[0] == "attach":
        mount = pathlib.Path(args[args.index("-mountpoint") + 1])
        shutil.copytree(root / "dist/VaultSSH.app", mount / "VaultSSH.app")
        (mount / "Applications").symlink_to("/wrong" if os.environ.get("BROKEN_LINK") else "/Applications")
'''


class PackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vaultssh-package-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts/package.sh", scripts / "package.sh")
        (self.root / "VERSION").write_text("1.2.3\n")
        (scripts / "build.sh").write_text(
            '#!/bin/bash\nset -eu\ncd "$(dirname "$0")/.."\n'
            'mkdir -p dist/VaultSSH.app/Contents/MacOS\n'
            'printf fixture > dist/VaultSSH.app/Contents/MacOS/VaultSSH\n'
        )
        (scripts / "verify-app.sh").write_text(
            '#!/bin/bash\nset -eu\ntest -f "$1/Contents/MacOS/VaultSSH"\n'
        )
        for script in scripts.iterdir():
            script.chmod(0o755)
        binaries = self.root / "bin"
        binaries.mkdir()
        for name in ["lipo", "xcrun", "codesign", "spctl", "hdiutil"]:
            tool = binaries / name
            tool.write_text(TOOLS)
            tool.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                        PACKAGE_TEST_ROOT=str(self.root),
                        SIGNING_IDENTITY="Developer ID Application: Test (TESTID)",
                        NOTARY_PROFILE="test-profile", NOTARY_KEYCHAIN="/test/keychain")

    def run_package(self, **environment):
        return subprocess.run(["bash", str(self.root / "scripts/package.sh")],
                              env=dict(self.env, **environment), capture_output=True,
                              text=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def assert_no_assets(self):
        self.assertFalse(list((self.root / "dist").glob("*.zip")))
        self.assertFalse(list((self.root / "dist").glob("*.dmg")))
        self.assertFalse(list((self.root / "dist").glob("*.sha256")))

    def test_missing_signing_pair_stops_before_build(self):
        for configuration in [{"SIGNING_IDENTITY": "-"}, {"NOTARY_PROFILE": ""}]:
            with self.subTest(configuration=configuration):
                result = self.run_package(**configuration)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "dist").exists())

    def test_rejected_app_or_dmg_never_produces_release_assets(self):
        for extension in [".zip", ".dmg"]:
            with self.subTest(extension=extension):
                result = self.run_package(REJECT_EXTENSION=extension)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Notarization failed: Invalid", result.stderr)
                self.assert_no_assets()

    def test_invalid_installer_link_is_rejected_and_unmounted(self):
        result = self.run_package(BROKEN_LINK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_assets()
        self.assertTrue(any(call[:2] == ["hdiutil", "detach"] for call in self.calls()))

    def test_signed_outputs_are_hashed_after_stapling(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        for extension in ["zip", "dmg"]:
            asset = self.root / f"dist/VaultSSH-1.2.3-macos-arm64.{extension}"
            self.assertTrue(asset.is_file())
            checksum, filename = Path(str(asset) + ".sha256").read_text().split()
            self.assertEqual(filename, asset.name)
            self.assertEqual(checksum, hashlib.sha256(asset.read_bytes()).hexdigest())
        self.assertTrue(asset.read_bytes().endswith(b"stapled-ticket"))
        submissions = [call for call in self.calls() if call[:3] == ["xcrun", "notarytool", "submit"]]
        self.assertEqual(len(submissions), 2)
        self.assertTrue(all("/test/keychain" in call for call in submissions))

    def test_ad_hoc_outputs_do_not_contact_apple(self):
        result = self.run_package(SIGNING_IDENTITY="-", NOTARY_PROFILE="")
        self.assertEqual(result.returncode, 0, result.stderr)
        for extension in ["zip", "dmg"]:
            asset = self.root / f"dist/VaultSSH-1.2.3-macos-arm64-ad-hoc.{extension}"
            self.assertTrue(asset.is_file())
            checksum, filename = Path(str(asset) + ".sha256").read_text().split()
            self.assertEqual(filename, asset.name)
            self.assertEqual(checksum, hashlib.sha256(asset.read_bytes()).hexdigest())
        self.assertFalse(any(call[0] == "xcrun" for call in self.calls()))


class ReleaseNotesTests(unittest.TestCase):
    def test_release_warning_matches_selected_mode(self):
        with tempfile.TemporaryDirectory(prefix="vaultssh-release-notes-test-") as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            script = root / "scripts/release-notes.py"
            shutil.copy2(ROOT / "scripts/release-notes.py", script)
            (root / "CHANGELOG.md").write_text(
                "## [Unreleased]\n\n- Upcoming change.\n\n"
                "## [1.2.3] - 2026-11-08\n\n- Reviewed change.\n"
            )
            for flags, warning in [([], True), (["--signing", "ad-hoc"], True),
                                   (["--signing", "notarized"], False)]:
                with self.subTest(flags=flags):
                    result = subprocess.run(["python3", str(script), "v1.2.3", *flags],
                                            capture_output=True, text=True, check=True)
                    self.assertEqual("has not been notarized" in result.stdout, warning)
                    self.assertIn("Reviewed change.", result.stdout)
                    self.assertNotIn("Upcoming change.", result.stdout)
            invalid = subprocess.run(["python3", str(script), "v1.2.3", "--signing", "typo"],
                                     capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertEqual(invalid.stdout, "")


if __name__ == "__main__":
    unittest.main()
