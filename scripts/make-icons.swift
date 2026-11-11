// Draws pointy — the mascot is the logo — at every size the product needs, so
// all icons come from one drawing:
//
//   swift scripts/make-icons.swift
//
// Writes app/AppIcon.icns, app/MenuIcon*.png (a black template image the menu
// bar tints), extension/icons/*.png and site/apple-touch-icon.png.
// Two variants: "full" has his marker poking out of the top-right corner;
// "face" drops it for sizes where it would turn to mush.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let lime = NSColor(srgbRed: 0xC8 / 255, green: 0xF5 / 255, blue: 0x3C / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)

/// full: face + marker. face: just the face. template: black outline for the menu bar.
/// plate: the app icon — the face fills Apple's icon shape edge to edge. macOS 26
/// puts any icon that doesn't fill that shape on a grey plate of its own.
enum Variant { case full, face, template, plate }

/// One drawing. `s` is the canvas edge in pixels; `inset` is the margin around the body.
func draw(_ s: CGFloat, _ variant: Variant, inset: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)              // y down, like the SVGs

    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let w = body.width
    let line = variant == .template ? w * 0.085 : variant == .plate ? max(w * 0.032, 1.2) : max(w * 0.045, 1.6)    // thicker when tiny
    let stroke = variant == .template ? NSColor.black : ink

    if variant == .full {
        // The marker sits behind his top-right corner, tip up and out.
        ctx.saveGState()
        // Pivot and length keep the tip inside the canvas at every size.
        ctx.translateBy(x: body.maxX - w * 0.12, y: body.minY + w * 0.14)
        ctx.rotate(by: .pi * 0.18)
        let mw = w * 0.12, ml = w * 0.34
        ctx.setFillColor(ink.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -mw / 2, y: -ml * 0.62, width: mw, height: ml), cornerWidth: mw * 0.35, cornerHeight: mw * 0.35, transform: nil))
        ctx.fillPath()
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: -mw * 0.42, y: -ml * 0.60)); tip.addLine(to: CGPoint(x: mw * 0.42, y: -ml * 0.60))
        tip.addLine(to: CGPoint(x: 0, y: -ml * 0.86)); tip.closeSubpath()
        ctx.setFillColor(lime.cgColor); ctx.addPath(tip); ctx.fillPath()
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(line * 0.7); ctx.setLineJoin(.round); ctx.addPath(tip); ctx.strokePath()
        ctx.restoreGState()
    }

    // The body: lime rounded square with a thick black edge.
    let r = variant == .plate ? w * 0.225 : w * 0.27
    let bodyPath = CGPath(roundedRect: body.insetBy(dx: line / 2, dy: line / 2), cornerWidth: r, cornerHeight: r, transform: nil)
    if variant != .template { ctx.setFillColor(lime.cgColor); ctx.addPath(bodyPath); ctx.fillPath() }
    ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(line); ctx.addPath(bodyPath); ctx.strokePath()

    // Face: two dot eyes and a small smile, placed as on the landing-page mascot.
    let eyeR = w * (variant == .template ? 0.085 : 0.062)
    ctx.setFillColor(stroke.cgColor)
    for x in [0.36, 0.64] {
        ctx.fillEllipse(in: CGRect(x: body.minX + w * x - eyeR, y: body.minY + w * 0.43 - eyeR, width: eyeR * 2, height: eyeR * 2))
    }
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: body.minX + w * 0.39, y: body.minY + w * 0.63))
    smile.addQuadCurve(to: CGPoint(x: body.minX + w * 0.61, y: body.minY + w * 0.63),
                       control: CGPoint(x: body.midX, y: body.minY + w * 0.76))
    ctx.setLineWidth(variant == .template ? line : line * 0.95); ctx.setLineCap(.round)
    ctx.addPath(smile); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// App icon.
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(pt * scale)
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        // Apple's grid: the icon shape is 824 of 1024, centred.
        save(draw(px, .plate, inset: px * 100 / 1024), "build/AppIcon.iconset/\(name)")
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("app/AppIcon.icns").path]
try! iconutil.run(); iconutil.waitUntilExit()

// Menu bar: an 18pt template image, @1x and @2x.
save(draw(18, .template, inset: 1.5), "app/MenuIcon.png")
save(draw(36, .template, inset: 3), "app/MenuIcon@2x.png")

// Extension toolbar and store icons.
for px in [16, 32, 48, 128] {
    save(draw(CGFloat(px), px < 48 ? .face : .full, inset: CGFloat(px) * (px < 48 ? 0.06 : 0.1)), "extension/icons/icon\(px).png")
}

// Landing page: home-screen icon (the favicon itself is an SVG in site/).
save(draw(180, .full, inset: 18), "site/apple-touch-icon.png")
print("icons written")
