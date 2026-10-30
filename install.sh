#!/usr/bin/env bash
# Install / manage the localsocks proxy as a system service.
#
#   ./install.sh system      # LaunchDaemon in /Library/LaunchDaemons  (needs sudo)
#   ./install.sh user        # LaunchAgent in ~/Library/LaunchAgents   (no sudo)
#   ./install.sh uninstall [system|user]
#   ./install.sh restart   [system|user]
#   ./install.sh status
#   ./install.sh logs
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.localsocks.hysteria2"
PLIST_LOCAL="$DIR/launchd/$LABEL.plist"
DOMAIN_USER="gui/$(id -u)"
DOMAIN_SYSTEM="system"
TARGET_SYSTEM="/Library/LaunchDaemons/$LABEL.plist"
TARGET_USER="$HOME/Library/LaunchAgents/$LABEL.plist"

render_plist() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  cat >"$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/daemon.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$DIR</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HYS2_CONF</key>
        <string>$DIR/hysteria2-client.yaml</string>
        <key>HYS2_BIN</key>
        <string>$DIR/bin/hysteria</string>
        <key>HYS2_LOG_DIR</key>
        <string>$DIR/logs</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ExitTimeOut</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>5</integer>
    <key>UserName</key>
    <string>$(id -un)</string>

    <key>StandardOutPath</key>
    <string>$DIR/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/logs/launchd.err.log</string>
</dict>
</plist>
PLIST
}

do_install_system() {
  render_plist "$PLIST_LOCAL"
  plutil -lint "$PLIST_LOCAL" >/dev/null
  mkdir -p "$DIR/logs"
  echo "==> installing LaunchDaemon (runs as $(id -un), restarts forever)"
  sudo cp "$PLIST_LOCAL" "$TARGET_SYSTEM"
  sudo chown root:wheel "$TARGET_SYSTEM"
  sudo chmod 644 "$TARGET_SYSTEM"
  sudo launchctl bootout "$DOMAIN_SYSTEM/$LABEL" 2>/dev/null || true
  # bootstrap 对 disabled 标签会报 EIO("Bootstrap failed: 5")，先清掉禁用标记
  sudo launchctl enable "$DOMAIN_SYSTEM/$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap "$DOMAIN_SYSTEM" "$TARGET_SYSTEM"
  sudo launchctl kickstart -k "$DOMAIN_SYSTEM/$LABEL"
  echo "==> started. check: ./install.sh status"
}

do_install_user() {
  render_plist "$PLIST_LOCAL"
  plutil -lint "$PLIST_LOCAL" >/dev/null
  mkdir -p "$DIR/logs" "$HOME/Library/LaunchAgents"
  echo "==> installing LaunchAgent (starts at login)"
  cp "$PLIST_LOCAL" "$TARGET_USER"
  launchctl bootout "$DOMAIN_USER/$LABEL" 2>/dev/null || true
  # 同上：关掉时写下的 disable 标记会阻挠 bootstrap
  launchctl enable "$DOMAIN_USER/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN_USER" "$TARGET_USER"
  launchctl kickstart -k "$DOMAIN_USER/$LABEL"
  echo "==> started. check: ./install.sh status"
}

do_uninstall() {
  local mode="${1:-system}"
  if [ "$mode" = "system" ]; then
    sudo launchctl bootout "$DOMAIN_SYSTEM/$LABEL" 2>/dev/null || true
    sudo rm -f "$TARGET_SYSTEM"
  else
    launchctl bootout "$DOMAIN_USER/$LABEL" 2>/dev/null || true
    rm -f "$TARGET_USER"
  fi
  echo "==> removed ($mode)"
}

do_restart() {
  local mode="${1:-system}"
  if [ "$mode" = "system" ]; then
    sudo launchctl kickstart -k "$DOMAIN_SYSTEM/$LABEL"
  else
    launchctl kickstart -k "$DOMAIN_USER/$LABEL"
  fi
  echo "==> restarted ($mode)"
}

do_status() {
  echo "-- launchctl (system)"; sudo launchctl print "$DOMAIN_SYSTEM/$LABEL" 2>/dev/null | sed -n '1,12p' || echo "   not loaded"
  echo "-- launchctl (user)";   launchctl print "$DOMAIN_USER/$LABEL" 2>/dev/null | sed -n '1,12p' || echo "   not loaded"
  echo "-- listener"; nc -z 127.0.0.1 10800 && echo "   127.0.0.1:10800 open" || echo "   127.0.0.1:10800 closed"
  echo "-- daemon pid"; [ -f "$DIR/logs/daemon.pid" ] && cat "$DIR/logs/daemon.pid" || echo "   none"
}

case "${1:-}" in
  system)    do_install_system ;;
  user)      do_install_user ;;
  uninstall) do_uninstall "${2:-system}" ;;
  restart)   do_restart "${2:-system}" ;;
  status)    do_status ;;
  render)    render_plist "$PLIST_LOCAL"; plutil -lint "$PLIST_LOCAL"; echo "==> wrote $PLIST_LOCAL" ;;
  logs)      tail -n 40 -f "$DIR/logs/hysteria2.log" ;;
  *)
    sed -n '2,12p' "$0"
    exit 1
    ;;
esac
