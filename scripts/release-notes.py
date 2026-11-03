#!/usr/bin/env python3
"""Extract reviewed changelog notes; never invent release claims from commits."""
from pathlib import Path
import re
import sys

version = sys.argv[1].removeprefix("v")
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    sys.exit("Expected vX.Y.Z")
text = Path(__file__).resolve().parent.parent.joinpath("CHANGELOG.md").read_text()
section = re.search(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if not section or not section[1].strip():
    sys.exit(f"Missing dated changelog entry for {version}")
print("This draft contains an **ad-hoc signed, unnotarized Apple Silicon build for testing**. "
      "It is not a Gatekeeper-approved distribution.\n")
print(section[1].strip())
print("\nVerify the download with `shasum -a 256 -c <archive>.sha256`. "
      "Quit VaultSSH before replacing the app in Applications. "
      "See [installation and limitations](https://github.com/ruibaby/VaultSSH#readme).")
