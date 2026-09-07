#!/bin/bash
# Compiles Uberkey.swift into ~/Applications/Uberkey.app
set -euo pipefail

APP="${1:-$HOME/Applications/Uberkey.app}"
BUNDLE_ID="agency.honcho.uberkey"
IDENTITY="Uberkey Self-Signed"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Rendered from an SF Symbol rather than kept as an art asset. Cached; delete the .icns to
# regenerate after changing make-icon.swift.
if [[ ! -f Uberkey.icns ]]; then
  swift make-icon.swift && iconutil -c icns Uberkey.iconset -o Uberkey.icns && rm -rf Uberkey.iconset
fi
cp Uberkey.icns "$APP/Contents/Resources/Uberkey.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Uberkey</string>
  <key>CFBundleDisplayName</key><string>Uberkey</string>
  <key>CFBundleIdentifier</key><string>agency.honcho.uberkey</string>
  <key>CFBundleExecutable</key><string>Uberkey</string>
  <key>CFBundleIconFile</key><string>Uberkey</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O -o "$APP/Contents/MacOS/Uberkey" \
  -target "$(uname -m)-apple-macos13.0" \
  -framework Cocoa -framework IOKit \
  Uberkey.swift

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  # Stable certificate: the designated requirement pins the bundle id and cert rather than
  # the cdhash, so the Accessibility grant survives this rebuild. Nothing to reset.
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "Built $APP  (signed by \"$IDENTITY\" — Accessibility grant preserved)"
else
  # Ad-hoc fallback: the signature changes every build, which silently voids the grant
  # while leaving the checkbox on. Reset it so the app asks again cleanly instead.
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
  pkill -f "$APP" 2>/dev/null || true          # tccutil only works with the app stopped
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "Built $APP  (ad-hoc: re-grant Accessibility. Run ./make-cert.sh to stop this.)"
fi

# Pick up the new binary if the launch agent is installed.
if launchctl print "gui/$UID/$BUNDLE_ID" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID/$BUNDLE_ID"
  echo "Restarted the launch agent."
fi
