// Renders Uberkey.icns from the same SF Symbol the menu bar item uses, so the icon needs
// no art asset and cannot drift from the app. Run via build.sh; regenerated only if absent.
import AppKit

_ = NSApplication.shared        // symbol lookup needs AppKit initialised

let glyph = "capslock.fill"
let top = NSColor(srgbRed: 0.42, green: 0.38, blue: 0.92, alpha: 1)
let bottom = NSColor(srgbRed: 0.20, green: 0.15, blue: 0.62, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(px)
    // macOS app icons sit inside their canvas rather than filling it.
    let inset = side * 0.055
    let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: plate,
                                xRadius: plate.width * 0.225,
                                yRadius: plate.width * 0.225)
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // Subtle top highlight, so it does not read as a flat rectangle at large sizes.
    squircle.setClip()
    NSGradient(starting: NSColor(white: 1, alpha: 0.22), ending: NSColor(white: 1, alpha: 0))!
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
              angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let s = symbol.size
        let box = NSRect(x: (side - s.width) / 2, y: (side - s.height) / 2,
                         width: s.width, height: s.height)
        // Fill the symbol's alpha with white rather than tinting the drawn result.
        let white = NSImage(size: s)
        white.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: s))
        NSColor.white.set()
        NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
        white.unlockFocus()
        white.draw(in: box)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// iconutil expects this exact set of names.
let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let dir = URL(fileURLWithPath: "Uberkey.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (px, name) in variants {
    try render(px).write(to: dir.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to Uberkey.iconset")
