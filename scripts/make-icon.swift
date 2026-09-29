// Renders assets/AppIcon.icns: the bare signpost glyph with a blue→violet gradient and a soft shadow — no plate behind it.
// Usage: swiftc scripts/make-icon.swift -o /tmp/mkicon && /tmp/mkicon assets && iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

func png(size: Int) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        guard let sym = NSImage(systemSymbolName: "signpost.right.and.left.fill", accessibilityDescription: nil),
              let cfg = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: s * 0.72, weight: .semibold)) else { return true }
        // glyph as a mask, filled with the gradient
        let mask = NSImage(size: cfg.size)
        mask.lockFocus(); cfg.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.black.set(); NSRect(origin: .zero, size: cfg.size).fill(using: .sourceIn); mask.unlockFocus()
        let filled = NSImage(size: cfg.size)
        filled.lockFocus()
        NSGradient(colors: [NSColor(red: 0.30, green: 0.56, blue: 1.0, alpha: 1), NSColor(red: 0.58, green: 0.36, blue: 1.0, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: cfg.size), angle: -60)
        mask.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        filled.unlockFocus()
        let scale = min(1, (s * 0.86) / max(cfg.size.width, cfg.size.height))
        let w = cfg.size.width * scale, h = cfg.size.height * scale
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.30); shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        filled.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
let iconset = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! png(size: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("iconset written")
