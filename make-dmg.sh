#!/bin/bash
# Builds Uberkey.app and packages it as a DMG whose window shows "drag this there".
# No dependencies: the background is rendered with AppKit, the layout set with Finder.
set -euo pipefail

VOL="Uberkey"
APP="dist/Uberkey.app"
STAGE="dist/stage"
DMG="dist/Uberkey.dmg"
W=660; H=420

rm -rf dist
mkdir -p "$STAGE/.background"
./build.sh "$PWD/$APP"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# --- background image ---------------------------------------------------------------
cat > dist/bg.swift <<'SWIFT'
import AppKit
_ = NSApplication.shared

let w = 660.0, h = 420.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * 2, pixelsHigh: Int(h) * 2,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1),
           ending: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.95, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ colour: NSColor, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour,
    ]
    let a = NSAttributedString(string: s, attributes: attrs)
    a.draw(at: NSPoint(x: (w - a.size().width) / 2, y: y))
}

text("Uberkey", 26, .semibold, NSColor(white: 0.12, alpha: 1), y: h - 66)
text("Drag Uberkey into your Applications folder", 13, .regular,
     NSColor(white: 0.38, alpha: 1), y: h - 94)
text("First launch: right-click Uberkey and choose Open", 11, .regular,
     NSColor(white: 0.55, alpha: 1), y: 34)

// Arrow between where Finder will place the two icons. Finder measures icon positions
// from the top-left, AppKit draws from the bottom-left, so this has to be flipped or the
// arrow sits below the icons rather than between them.
let iconY = 196.0          // must match the Finder positions set in the AppleScript below
let arrow = NSBezierPath()
let midY = h - iconY
arrow.move(to: NSPoint(x: 258, y: midY))
arrow.line(to: NSPoint(x: 408, y: midY))
NSColor(white: 0.62, alpha: 1).setStroke()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 394, y: midY + 11))
head.line(to: NSPoint(x: 412, y: midY))
head.line(to: NSPoint(x: 394, y: midY - 11))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "dist/bg.png"))
SWIFT
swift dist/bg.swift
cp dist/bg.png "$STAGE/.background/bg.png"

# --- build a writable image, lay it out, then compress -------------------------------
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
  -format UDRW -ov dist/rw.dmg >/dev/null
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen dist/rw.dmg | grep -o '/Volumes/.*' | head -1)

# Finder owns icon positions and the window background, and only AppleScript can set them.
# If automation is not permitted this fails harmlessly and the DMG still installs fine —
# it just opens as a plain file list.
osascript <<APPLESCRIPT || echo "note: could not set the window layout (Finder automation not permitted)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, $((200 + W)), $((120 + H))}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:bg.png"
    set position of item "Uberkey.app" of container window to {180, 196}
    set position of item "Applications" of container window to {480, 196}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert dist/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f dist/rw.dmg dist/bg.swift

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
