#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CXSTray.app"
LABEL="com.cxs.tray"
INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="${INSTALL_DIR}/${APP_NAME}"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
UID_VALUE="$(id -u)"

cd "$ROOT"

bash scripts/build-app.sh >/dev/null

mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR"

if launchctl print "gui/${UID_VALUE}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/${UID_VALUE}" "$PLIST" >/dev/null 2>&1 || true
fi

osascript -e 'quit app id "com.cxs.tray"' >/dev/null 2>&1 || true
ditto "$ROOT/.build/release/${APP_NAME}" "$INSTALL_APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>${INSTALL_APP}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/${LABEL}.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/${LABEL}.err.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/${UID_VALUE}" "$PLIST"
launchctl kickstart -k "gui/${UID_VALUE}/${LABEL}" >/dev/null 2>&1 || true

echo "Installed ${INSTALL_APP}"
echo "Registered ${PLIST}"
