#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for script in scripts/*.sh; do bash -n "$script"; done
UNFORMATTED="$(gofmt -l agent/*.go)"
[[ -z "$UNFORMATTED" ]] || { printf 'Run gofmt on:\n%s\n' "$UNFORMATTED" >&2; exit 1; }
swift test
(cd agent && go vet ./... && go test -race -buildvcs=false ./...)
./scripts/build.sh
python3 scripts/test-agent.py dist/VaultSSH.app/Contents/MacOS/bwssh-agent
