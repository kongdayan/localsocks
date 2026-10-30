#!/usr/bin/env bash
# Supervisor loop for the Hysteria2 client.
#
# Started by launchd / systemd, but runs standalone too:
#   ./daemon.sh
#
# Behaviour: runs the client in the foreground, and if it exits for any reason
# (crash, network drop, node restart, TLS failure) retries forever with
# exponential backoff 1s -> 60s. Backoff resets once a session has stayed up
# long enough to be considered healthy.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

CONF="${HYS2_CONF:-$DIR/hysteria2-client.yaml}"
BIN="${HYS2_BIN:-$DIR/bin/hysteria}"
LOG_DIR="${HYS2_LOG_DIR:-$DIR/logs}"
LOG="$LOG_DIR/hysteria2.log"
PID_FILE="$LOG_DIR/daemon.pid"
MIN_BACKOFF="${HYS2_MIN_BACKOFF:-1}"
MAX_BACKOFF="${HYS2_MAX_BACKOFF:-60}"
HEALTHY_AFTER="${HYS2_HEALTHY_AFTER:-30}"   # seconds of uptime that resets backoff

mkdir -p "$LOG_DIR"
echo $$ >"$PID_FILE"

CHILD=""
shutdown() {
  hys2log "$LOG" "signal received, stopping"
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
  wait "$CHILD" 2>/dev/null
  rm -f "$PID_FILE"
  exit 0
}
trap shutdown TERM INT

if [ ! -f "$CONF" ]; then
  hys2log "$LOG" "FATAL config not found: $CONF"
  exit 78   # EX_CONFIG
fi

hys2log "$LOG" "supervisor start pid=$$ conf=$CONF"
backoff="$MIN_BACKOFF"

while :; do
  if ! ensure_binary "$BIN" >>"$LOG" 2>&1; then
    hys2log "$LOG" "binary unavailable, retry in ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 > MAX_BACKOFF ? MAX_BACKOFF : backoff * 2 ))
    continue
  fi

  rotate_file "$LOG" 5242880

  started="$(date +%s)"
  hys2log "$LOG" "launching client"
  "$BIN" client -c "$CONF" >>"$LOG" 2>&1 &
  CHILD=$!
  wait "$CHILD"
  rc=$?
  uptime=$(( $(date +%s) - started ))
  CHILD=""

  if [ "$rc" -eq 0 ]; then
    hys2log "$LOG" "client exited cleanly after ${uptime}s"
  else
    hys2log "$LOG" "client died rc=$rc after ${uptime}s"
  fi

  if [ "$uptime" -ge "$HEALTHY_AFTER" ]; then
    backoff="$MIN_BACKOFF"
  fi
  hys2log "$LOG" "reconnecting in ${backoff}s"
  sleep "$backoff"
  backoff=$(( backoff * 2 > MAX_BACKOFF ? MAX_BACKOFF : backoff * 2 ))
done
