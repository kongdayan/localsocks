#!/usr/bin/env bash
# Health probe for the local proxy.
#   ./healthcheck.sh              # report only
#   ./healthcheck.sh --restart    # restart the launchd service if the probe fails
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY="socks5h://127.0.0.1:10800"
MODE="${1:-}"

fail=0
note() { printf '%s\n' "$*"; }

# 1. local listener
if nc -z 127.0.0.1 10800 2>/dev/null; then
  note "OK   listener 127.0.0.1:10800"
else
  note "FAIL listener 127.0.0.1:10800"
  fail=1
fi

# 2. end-to-end egress through the node
egress="$(curl -s --max-time 20 --proxy "$PROXY" https://api.ipify.org || true)"
if [ -n "$egress" ]; then
  note "OK   egress via proxy: $egress"
else
  note "FAIL egress via proxy (no response in 20s)"
  fail=1
fi

# 3. supervisor alive?
if [ -f "$DIR/logs/daemon.pid" ] && kill -0 "$(cat "$DIR/logs/daemon.pid")" 2>/dev/null; then
  note "OK   supervisor pid=$(cat "$DIR/logs/daemon.pid")"
else
  note "WARN no live supervisor pid (service may be stopped)"
fi

if [ "$fail" -ne 0 ] && [ "$MODE" = "--restart" ]; then
  note "==> probe failed, restarting service"
  "$DIR/install.sh" restart system 2>/dev/null || "$DIR/install.sh" restart user
fi

exit "$fail"
