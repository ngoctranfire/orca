#!/bin/bash
# Install (or reinstall) the daily upstream sync as a launchd job.
# The script is copied out of the repo so a rebase can never rewrite it mid-run.
# Usage: .spyhop/install.sh [HOUR]   (default 9 = 9:00 local; runs on wake if the Mac was asleep)
# Uninstall: launchctl bootout gui/$(id -u)/com.spyhop.sync-upstream && rm ~/Library/LaunchAgents/com.spyhop.sync-upstream.plist

set -euo pipefail

LABEL=com.spyhop.sync-upstream
HOUR="${1:-9}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/Library/Application Support/spyhop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$BIN_DIR" "$HOME/Library/Logs/spyhop" "$HOME/Library/LaunchAgents"
install -m 755 "$REPO/.spyhop/sync-upstream.sh" "$BIN_DIR/sync-upstream.sh"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN_DIR/sync-upstream.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SPYHOP_REPO</key><string>$REPO</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/spyhop/launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/spyhop/launchd.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL: daily at $HOUR:00 for $REPO"
echo "Logs: ~/Library/Logs/spyhop/sync-upstream.log   Run now: launchctl kickstart gui/$(id -u)/$LABEL"
