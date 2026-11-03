#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Run both scanners even when one reports advisories. No suppressions or force fixes.
result=0
(cd "$ROOT/agent" && go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...) || result=1
(cd "$ROOT/Sources/VaultSSH/Resources/CLI" && npm audit --package-lock-only --omit=dev --audit-level=high) || result=1
exit "$result"
