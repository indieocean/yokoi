// Regenerates the app icon set and README icon from a square logo with a light background.
// swift scripts/make-icon.swift assets/ui/yokoi-logo.jpg Yokoi/Assets.xcassets/AppIcon.appiconset assets/readme/icon.png
import AppKit
import CoreGraphics

// Usage: iconize <source.jpg> <out-dir> <readme-icon.png>
let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!
var rect = CGRect(origin: .zero, size: src.size)
let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let w = cg.width, h = cg.height

// 1. Read pixels and find the dark tile's bounding box (background is light gray).
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
var px = [UInt8](repeating: 0, count: w * h * 4)
let rctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
func lum(_ x: Int, _ y: Int) -> Double {
    let i = (y * w + x) * 4
    return (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
}
// Scan the middle row/column for where the dark tile starts and ends.
func edges(_ along: (Int) -> Double, _ n: Int) -> (Int, Int) {
    var a = 0, b = n - 1
    while a < n && along(a) > 0.45 { a += 1 }
    while b > 0 && along(b) > 0.45 { b -= 1 }
    return (a, b)
}
let (x0, x1) = edges({ lum($0, h / 2) }, w)
let (y0, y1) = edges({ lum(w / 2, $0) }, h)
print("tile bbox x:\(x0)-\(x1) y:\(y0)-\(y1)  (\(x1 - x0 + 1)x\(y1 - y0 + 1))")
// Bitmap rows are top-down; CGImage cropping uses top-left origin.
let side = min(x1 - x0, y1 - y0) + 1
let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: side, height: side))!

// 2. Apple-style superellipse ("squircle") path.
func squircle(_ r: CGRect, n: Double = 5.0) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

// 3. Render the master: 1024 canvas, 824 body at 100px inset (Apple macOS grid), soft shadow.
func render(_ size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = squircle(body)
    // Shadow (drawn with the shape filled, then the artwork on top).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.19, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // Artwork clipped to the squircle. Draw the crop slightly larger so the old rounded corners
    // (and any gray) fall outside the new shape.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bleed = 824 * s * 0.035
    ctx.draw(crop, in: body.insetBy(dx: -bleed, dy: -bleed))
    ctx.restoreGState()
    // Hairline inner edge for definition on dark backgrounds.
    ctx.addPath(squircle(body.insetBy(dx: 0.75 * s, dy: 0.75 * s)))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(1.5 * s)
    ctx.strokePath()
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = args[2]
for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        write(render(s * scale), "\(out)/icon_\(s)x\(s)\(scale == 2 ? "@2x" : "").png")
    }
}
write(render(1024), args[3])
print("done")
