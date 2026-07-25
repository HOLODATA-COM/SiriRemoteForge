// make_repo_avatar.swift — generates the GitHub repo avatar + social-preview image, sharing the
// app icon's visual identity (space-gray body, blue accent glow, silver 3rd-gen Siri Remote glyph)
// but FULL-BLEED (no squircle inset) so it reads cleanly under GitHub's circular / rounded crop.
//
//   swift tools/make_repo_avatar.swift <out_dir>
//
// Writes <out_dir>/logo.png (1024×1024 avatar) and <out_dir>/social-preview.png (1280×640).
import AppKit

// Shared palette (matches make_app_icon.swift).
let bodyGradient = NSGradient(colors: [
    NSColor(srgbRed: 0.205, green: 0.215, blue: 0.245, alpha: 1),
    NSColor(srgbRed: 0.10,  green: 0.105, blue: 0.125, alpha: 1),
    NSColor(srgbRed: 0.045, green: 0.05,  blue: 0.062, alpha: 1),
])!
let accentBlue = NSColor(srgbRed: 0.18, green: 0.44, blue: 0.96, alpha: 1)
let silver = NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1)

/// The silver remote glyph, rendered to fill a box of height `h` centered at `center`.
func drawRemoteGlyph(_ ctx: CGContext, canvasH: CGFloat, targetH: CGFloat, center: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: targetH, weight: .regular)
        .applying(.init(paletteColors: [silver]))
    guard let sym = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return }
    let scale = targetH / sym.size.height
    let dw = sym.size.width * scale, dh = sym.size.height * scale
    let dr = NSRect(x: center.x - dw/2, y: center.y - dh/2, width: dw, height: dh)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -canvasH*0.008), blur: canvasH*0.03,
                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
    sym.draw(in: dr)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Top-down metal sheen over just the glyph.
    if let cg = sym.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.clip(to: dr, mask: cg)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.24), NSColor.white.withAlphaComponent(0.0)])!
            .draw(in: dr, angle: -90)
    }
    ctx.restoreGState()
}

/// Space-gray body + blue glow filling `rect`, glow centered on `glowCenter` (relative, -1…1).
func drawBackdrop(_ ctx: CGContext, rect: NSRect, glowSpan: CGFloat, glowCenter: NSPoint) {
    bodyGradient.draw(in: rect, angle: -90)
    let gr = NSRect(x: rect.midX - glowSpan/2, y: rect.midY - glowSpan/2, width: glowSpan, height: glowSpan)
    NSGradient(colors: [accentBlue.withAlphaComponent(0.42), accentBlue.withAlphaComponent(0.0)])!
        .draw(in: gr, relativeCenterPosition: glowCenter)
    // Soft top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: rect, angle: -90)
}

func makeAvatar(_ px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    drawBackdrop(ctx, rect: rect, glowSpan: px*0.95, glowCenter: NSPoint(x: 0, y: -0.18))
    drawRemoteGlyph(ctx, canvasH: px, targetH: px*0.62, center: NSPoint(x: px/2, y: px/2))
    // Inner rim for a touch of definition (invisible once GitHub circle-crops, harmless when square).
    NSColor.white.withAlphaComponent(0.06).setStroke()
    let rim = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)); rim.lineWidth = max(1, px*0.003); rim.stroke()
    img.unlockFocus()
    return img
}

func makeSocialPreview(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    drawBackdrop(ctx, rect: rect, glowSpan: h*1.6, glowCenter: NSPoint(x: -0.35, y: -0.1))

    // Left: the remote glyph. Right: title + tagline.
    let glyphH = h * 0.5
    let glyphCX = w * 0.22
    drawRemoteGlyph(ctx, canvasH: h, targetH: glyphH, center: NSPoint(x: glyphCX, y: h/2))

    let textX = w * 0.40
    let title = NSAttributedString(string: "SiriRemoteForge", attributes: [
        .font: NSFont.systemFont(ofSize: h*0.135, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let tagline = NSAttributedString(string: "Turn an Apple TV Siri Remote\ninto a Mac controller + virtual mic", attributes: [
        .font: NSFont.systemFont(ofSize: h*0.052, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.72),
    ])
    let titleSize = title.size()
    let tagSize = tagline.size()
    let gap = h * 0.045
    let blockH = titleSize.height + gap + tagSize.height
    var y = h/2 + blockH/2 - titleSize.height
    title.draw(at: NSPoint(x: textX, y: y))
    y -= (gap + tagSize.height)
    tagline.draw(at: NSPoint(x: textX, y: y))
    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to url: URL) throws {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let outArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let outDir = URL(fileURLWithPath: outArg, isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try writePNG(makeAvatar(1024), to: outDir.appendingPathComponent("logo.png"))
try writePNG(makeSocialPreview(1280, 640), to: outDir.appendingPathComponent("social-preview.png"))
print("wrote logo.png (1024×1024) + social-preview.png (1280×640) to \(outDir.path)")
