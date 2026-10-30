#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for file in "$ROOT"/*.sh; do bash -n "$file"; done
for file in "$ROOT"/macos/*.sh; do zsh -n "$file"; done
python3 -m json.tool "$ROOT/examples/nodes.example.json" >/dev/null
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
swiftc "$ROOT/macos/Core.swift" "$ROOT/tests/main.swift" -o "$TMP_DIR/config-check"
"$TMP_DIR/config-check"
