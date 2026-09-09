#!/bin/bash
# Builds Uberkey.app and packages it for download.
# The zip is what someone unzips and double-clicks; no scripts, no Xcode, no Homebrew.
set -euo pipefail

APP="dist/Uberkey.app"
ZIP="dist/Uberkey.zip"

# Only our own outputs: wiping all of dist would delete a DMG built alongside this.
mkdir -p dist
rm -rf "$APP" "$ZIP"
./build.sh "$PWD/$APP"

# ditto, not zip: it preserves the code signature and resource forks. A plain `zip` can
# leave the bundle unverifiable, which turns Gatekeeper's warning into a hard refusal.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
codesign --verify --deep --strict "$APP" && echo "signature verifies"
