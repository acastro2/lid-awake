#!/bin/bash
# Builds Lid Awake and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/Lid Awake.app"
BUILD="build"

rm -rf "$BUILD"
mkdir -p "$BUILD/Lid Awake.app/Contents/MacOS"

echo "compiling"
/usr/bin/swiftc -O -o "$BUILD/Lid Awake.app/Contents/MacOS/LidAwake" main.swift

cp Info.plist "$BUILD/Lid Awake.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$BUILD/Lid Awake.app" >/dev/null 2>&1

# Replace any previous install.
if [ -d "$APP" ]; then
    /usr/bin/osascript -e 'tell application "Lid Awake" to quit' >/dev/null 2>&1 || true
    /bin/rm -rf "$APP"
fi

/bin/cp -R "$BUILD/Lid Awake.app" "$APP"
/usr/bin/codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "installed: $APP"

# Login agent: starts the app at every login and restarts it if it dies.
AGENT="$HOME/Library/LaunchAgents/com.github.acastro2.lidawake.plist"
/bin/cp login-agent.plist "$AGENT"
/bin/launchctl bootout "gui/$(id -u)/com.github.acastro2.lidawake" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$(id -u)" "$AGENT" || /usr/bin/open "$APP"
echo "agent loaded, app launched"
