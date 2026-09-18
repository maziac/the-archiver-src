// Zeichnet das App-Icon und packt es mit iconutil nach Resources/AppIcon.icns.
// Aufruf: swift scripts/make_icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Hintergrund: abgerundetes Quadrat mit Verlauf
    let inset = s * 0.1
    let bg = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.16, green: 0.45, blue: 0.85, alpha: 1), CGColor(red: 0.08, green: 0.25, blue: 0.6, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.resetClip()

    // Zwei versetzte Blätter
    func sheet(_ r: CGRect, alpha: CGFloat) {
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil))
        ctx.fillPath()
    }
    let w = s * 0.4, h = s * 0.52
    sheet(CGRect(x: s * 0.36, y: s * 0.26, width: w, height: h), alpha: 0.55)
    let front = CGRect(x: s * 0.26, y: s * 0.2, width: w, height: h)
    sheet(front, alpha: 1)

    // Textzeilen
    ctx.setFillColor(CGColor(red: 0.6, green: 0.68, blue: 0.8, alpha: 1))
    for i in 0..<5 {
        let lw = w * (i == 4 ? 0.45 : 0.72)
        ctx.fill(CGRect(x: front.minX + w * 0.14, y: front.maxY - h * 0.3 - CGFloat(i) * h * 0.11, width: lw, height: h * 0.045))
    }
    // Nummernstempel oben rechts
    ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: front.maxX - w * 0.38, y: front.maxY - h * 0.15, width: w * 0.28, height: h * 0.07))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try fm.removeItem(at: iconset)
print("Resources/AppIcon.icns geschrieben")
