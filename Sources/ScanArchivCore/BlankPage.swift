import CoreGraphics
import Foundation

/// Erkennt leere Seiten (z. B. unbedruckte Rückseiten), damit „kein Text erkannt“ nur bei Seiten
/// mit Inhalt gemeldet wird.
public enum BlankPage {
    /// Helligkeit (0…255), unter der ein Pixel als Druck zählt. Von der Rückseite durchscheinender
    /// Text ist deutlich heller (meist über 200); dünne Striche bleiben nach dem Verkleinern darunter.
    static let inkThreshold: UInt8 = 160
    /// Höchstanteil dunkler Pixel einer leeren Seite (Staub, Kratzer).
    static let maxInkShare = 0.0005
    /// Ignorierter Rand links/rechts (Anteil je Seite): Scannerschatten, Lochung (Mitte ca. 12 mm vom Rand)
    /// und Maschinencodes der Post/Kuvertierung (DataMatrix, Strichmarken) am Seitenrand.
    static let marginX = 0.10
    /// Ignorierter Rand oben/unten (Lochung bei quer gescannten Seiten, Papierkanten).
    static let marginY = 0.06

    public static func isBlank(_ image: CGImage) -> Bool {
        inkShare(image) < maxInkShare
    }

    /// Anteil dunkler Pixel innerhalb des Randes.
    static func inkShare(_ image: CGImage) -> Double {
        let small = ImageTools.downscaled(image, maxPixel: 1000)
        let width = small.width, height = small.height
        // als 8-Bit-Graustufen ohne Zeilenauffüllung zeichnen, dann direkt zählen
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 1 }
        // Ränder auf die kurze bzw. lange Seite beziehen, damit auch Querformat passt
        let portrait = height >= width
        let dx = Int(Double(width) * (portrait ? marginX : marginY)), dy = Int(Double(height) * (portrait ? marginY : marginX))
        var ink = 0, total = 0
        for y in dy..<max(dy, height - dy) {
            let row = y * width
            for x in dx..<max(dx, width - dx) {
                total += 1
                if pixels[row + x] < inkThreshold { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }
}
