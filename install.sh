#!/bin/bash
# Starts Uberkey at login. The Caps Lock -> F18 remap is handled by the app itself.
# ./install.sh              install
# ./install.sh --uninstall  remove, restore Caps Lock
set -euo pipefail

APP="$HOME/Applications/Uberkey.app"
AGENTS="$HOME/Library/LaunchAgents"
APP_ID="agency.honcho.uberkey"
OLD_REMAP_ID="agency.honcho.uberkey.remap"   # superseded: the app does this now

if [[ "${1:-}" == "--uninstall" ]]; then
  for id in "$APP_ID" "$OLD_REMAP_ID"; do
    launchctl bootout "gui/$UID/$id" 2>/dev/null || true
    rm -f "$AGENTS/$id.plist"
  done
  pkill -f "Uberkey.app" 2>/dev/null || true
  hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
  # Leave nothing behind: the status/log/lock directory and the settings domain.
  rm -rf "$HOME/Library/Application Support/Uberkey"
  defaults delete agency.honcho.uberkey >/dev/null 2>&1 || true
  echo "Uninstalled. Caps Lock restored. Delete $APP to finish."
  exit 0
fi

[[ -d "$APP" ]] || { echo "Build it first: ./build.sh"; exit 1; }
mkdir -p "$AGENTS"

# The remap used to be its own RunAtLoad agent. The app now applies it on launch, on wake
# and on keyboard connect, and clears it on quit — so retire the old agent if present.
if [[ -f "$AGENTS/$OLD_REMAP_ID.plist" ]]; then
  launchctl bootout "gui/$UID/$OLD_REMAP_ID" 2>/dev/null || true
  rm -f "$AGENTS/$OLD_REMAP_ID.plist"
  echo "Retired the old $OLD_REMAP_ID agent (folded into the app)."
fi

# KeepAlive is SuccessfulExit=false, not true: quitting from the menu exits 0 and stays
# dead, while the wait-for-Accessibility retry exits non-zero and gets respawned.
cat > "$AGENTS/$APP_ID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$APP_ID</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/Uberkey</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/$APP_ID" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$AGENTS/$APP_ID.plist"

echo "Installed. Caps Lock is now the Uber key (⌃⌥⌘); quick tap sends Escape."
echo "Status: ~/Library/Application Support/Uberkey/status"
