// make_app_icon.swift — generates the HyperVibe app-icon .iconset (a space-gray squircle with a
// silver 3rd-gen Siri Remote glyph). Writes PNGs into the iconset directory given as the first
// argument (default ./HyperVibe.iconset). `create_app_bundle.sh` then runs `iconutil` to pack the
// .icns. Run standalone: `swift tools/make_app_icon.swift <out.iconset>`.
import AppKit

func makeIcon(_ px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = px

    let inset = s * 0.086
    let rect = NSRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
    let radius = (s - inset*2) * 0.2237
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    tile.addClip()

    // Space-gray vertical gradient body.
    NSGradient(colors: [
        NSColor(srgbRed: 0.205, green: 0.215, blue: 0.245, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.105, blue: 0.125, alpha: 1),
        NSColor(srgbRed: 0.045, green: 0.05, blue: 0.062, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    // Subtle blue accent glow, low-center, behind the remote.
    NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.44, blue: 0.96, alpha: 0.42),
        NSColor(srgbRed: 0.18, green: 0.44, blue: 0.96, alpha: 0.0),
    ])!.draw(in: NSRect(x: s*0.5 - s*0.46, y: s*0.5 - s*0.46, width: s*0.92, height: s*0.92),
             relativeCenterPosition: NSPoint(x: 0, y: -0.2))

    // Soft top sheen (fades to nothing — no hard edge).
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.10),
        NSColor.white.withAlphaComponent(0.0),
    ])!.draw(in: rect, angle: -90)

    // The remote glyph (SF Symbol), palette-tinted silver, centered — clean alpha (no mask tricks).
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sh = sym.size.height
        let scale = (s * 0.6) / sh
        let dw = sym.size.width * scale, dh = sh * scale
        let dr = NSRect(x: (s - dw)/2, y: (s - dh)/2, width: dw, height: dh)
        ctx.setShadow(offset: CGSize(width: 0, height: -s*0.010), blur: s*0.03,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        sym.draw(in: dr)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // Soft top-down sheen over just the glyph for a hint of metal.
        ctx.saveGState()
        dr.clip()
        if let cg = sym.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.clip(to: dr, mask: cg)
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])!
                .draw(in: dr, angle: -90)
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Crisp inner rim for definition.
    ctx.saveGState()
    tile.addClip()
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, s*0.004); rim.stroke()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

let outArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./HyperVibe.iconset"
let iconset = URL(fileURLWithPath: outArg)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    let rep = NSBitmapImageRep(data: makeIcon(px).tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote iconset to \(iconset.path)")
