#!/usr/bin/env python3
"""Extract reviewed changelog notes; never invent release claims from commits."""
from pathlib import Path
import argparse
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("tag")
parser.add_argument("--signing", choices=["ad-hoc", "notarized"], default="ad-hoc")
args = parser.parse_args()
version = args.tag.removeprefix("v")
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    sys.exit("Expected vX.Y.Z")
text = Path(__file__).resolve().parent.parent.joinpath("CHANGELOG.md").read_text()
section = re.search(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if not section or not section[1].strip():
    sys.exit(f"Missing dated changelog entry for {version}")
if args.signing == "ad-hoc":
    print("**This release is ad-hoc signed and has not been notarized by Apple.** "
          "macOS may block its first launch. See "
          "[installation instructions](https://github.com/ruibaby/VaultSSH#install).\n")
print(section[1].strip())
print("\nVerify the download with `shasum -a 256 -c <archive>.sha256`. "
      "Quit VaultSSH before replacing the app in Applications. "
      "See [installation and limitations](https://github.com/ruibaby/VaultSSH#readme).")
