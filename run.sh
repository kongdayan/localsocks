#!/usr/bin/env bash
# Foreground run (no supervision). For the always-on service use ./install.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

CONF="${HYS2_CONF:-$DIR/hysteria2-client.yaml}"
BIN="${HYS2_BIN:-$DIR/bin/hysteria}"

ensure_binary "$BIN"

echo "==> local SOCKS5 127.0.0.1:10800 | HTTP 127.0.0.1:10801"
exec "$BIN" client -c "$CONF"
