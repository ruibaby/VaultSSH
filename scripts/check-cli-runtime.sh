#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vaultssh-cli.XXXXXX")"
trap 'rm -rf "$RUNTIME_DIR"' EXIT
cp "$ROOT/Sources/VaultSSH/Resources/CLI/"{package.json,package-lock.json} "$RUNTIME_DIR/"
(cd "$RUNTIME_DIR" && npm ci --no-fund --no-audit)
node "$ROOT/scripts/test-cli-runtime.cjs" "$RUNTIME_DIR/node_modules/@bitwarden/cli/build/bw.js"
