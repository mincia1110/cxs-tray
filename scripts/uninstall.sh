#!/usr/bin/env bash
set -euo pipefail

LABEL="com.cxs.tray"
APP="${HOME}/Applications/CXSTray.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_VALUE="$(id -u)"

if launchctl print "gui/${UID_VALUE}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/${UID_VALUE}" "$PLIST" >/dev/null 2>&1 || true
fi

osascript -e 'quit app id "com.cxs.tray"' >/dev/null 2>&1 || true

rm -rf "$APP"
rm -f "$PLIST"

echo "Removed ${APP}"
echo "Removed ${PLIST}"
