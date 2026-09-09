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

# NEVER pipe into `grep -q` here. With `set -o pipefail` the early exit of grep -q closes
# the pipe, the producer takes SIGPIPE, and the pipeline reports failure even on a match.
# It is a race, so it works most times — and when it lost, this fell through to the ad-hoc
# branch below and ran tccutil reset, silently destroying a working Accessibility grant.
# Capture into a variable and match on the string instead.
signing_output=$(codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>&1) \
  && signed=yes || signed=no
identities=$(security find-identity -p codesigning 2>/dev/null || true)

if [[ "$signed" == yes ]]; then
  actual=$(codesign -dvv "$APP" 2>&1 || true)
  if [[ "$actual" != *"Authority=$IDENTITY"* ]]; then
    echo "ERROR: signed, but not by \"$IDENTITY\". Refusing to continue." >&2
    exit 1
  fi
  echo "Built $APP  (signed by \"$IDENTITY\" — Accessibility grant preserved)"
elif [[ "$identities" == *"$IDENTITY"* ]]; then
  echo "ERROR: signing failed: $signing_output" >&2
  echo "\"$IDENTITY\" exists, so this is not a missing identity. A locked login keychain" >&2
  echo "is the usual cause. Refusing to fall back to ad-hoc, because that would reset your" >&2
  echo "Accessibility grant." >&2
  exit 1
else
  # No identity at all. Ad-hoc signing changes the signature every build, which voids the
  # grant while leaving the checkbox on, so clear it to make the failure honest.
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
  pkill -f "$APP" 2>/dev/null || true          # tccutil only works with the app stopped
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "Built $APP  (ad-hoc: re-grant Accessibility. Run ./make-cert.sh to stop this.)"
fi

# The bundle is replaced on every build, so nudge LaunchServices or Finder can keep showing
# a stale icon (or none at all) for the new one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" >/dev/null 2>&1 || true

# Pick up the new binary if the launch agent is installed.
if launchctl print "gui/$UID/$BUNDLE_ID" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID/$BUNDLE_ID"
  echo "Restarted the launch agent."
fi
