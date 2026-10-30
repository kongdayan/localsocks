#!/usr/bin/env bash
# Verify the local proxy is up and exiting through the remote node.
set -euo pipefail
PROXY="socks5h://127.0.0.1:10800"

echo "-- TCP reachability"
nc -z 127.0.0.1 10800 && echo "  10800 open" || { echo "  10800 closed"; exit 1; }
nc -z 127.0.0.1 10801 2>/dev/null && echo "  10801 open (http)"

echo "-- egress IP via proxy"
curl -s --max-time 20 --proxy "$PROXY" https://api.ipify.org && echo

echo "-- direct IP (control)"
curl -s --max-time 10 https://api.ipify.org && echo
