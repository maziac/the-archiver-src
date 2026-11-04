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

    // MARK: Durchscheinende Vorderseite

    /// Rastergröße für den Vergleich (A4-Proportion, Zelle ca. 1,3 mm: fein genug für Wörter,
    /// grob genug für die Unschärfe durchs Papier).
    static let gridWidth = 160, gridHeight = 226
    /// größter geprüfter Versatz zwischen den Durchgängen (Rasterzellen, ca. 1 cm)
    static let maxShift = 8
    /// Mindestkorrelation mit der gespiegelten Vorderseite
    static let minShowThroughCorrelation = 0.5
    /// Durchschein erreicht höchstens diesen Anteil der Schwärze der Vorderseite; gedruckter Text
    /// auf einer echten Rückseite ist etwa so dunkel wie vorn.
    static let maxShowThroughDarkness = 0.7

    /// Die Rückseite zeigt nur die durchscheinende Vorderseite desselben Blatts (blass und
    /// spiegelverkehrt) – auf dem Papier ist sie leer. Erkannt am Vergleich mit der gespiegelten
    /// Vorderseite; wie der Stapel gewendet wurde (Längs- oder Querachse), spielt keine Rolle.
    public static func isShowThrough(_ back: CGImage, front: CGImage) -> Bool {
        let frontDark = darkness(front), backDark = darkness(back)
        guard frontDark > 100, backDark < frontDark * maxShowThroughDarkness else { return false }
        return showThroughCorrelation(back, front: front) >= minShowThroughCorrelation
    }

    /// Schwärze der dunkelsten Stellen (0…255): Druckdichte, die nur 0,2 % der Fläche übertreffen.
    static func darkness(_ image: CGImage) -> Double {
        guard let grid = inkGrid(image, width: 850, height: 1200) else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for v in grid { histogram[Int(v)] += 1 }
        var remaining = Int(Double(grid.count) * 0.002)
        for level in stride(from: 255, through: 0, by: -1) {
            remaining -= histogram[level]
            if remaining <= 0 { return Double(level) }
        }
        return 0
    }

    static func showThroughCorrelation(_ back: CGImage, front: CGImage) -> Double {
        let w = gridWidth, h = gridHeight
        guard let f = inkGrid(front, width: w, height: h), let b = inkGrid(back, width: w, height: h) else { return 0 }
        // Durchschein ist blasser als das Original; eine Vorderseite ohne Inhalt scheint nicht durch
        let meanF = f.reduce(0, +) / Double(f.count), meanB = b.reduce(0, +) / Double(b.count)
        guard meanF > 2, meanB < meanF else { return 0 }
        let coarseF = halved(f, width: w, height: h)
        var best = 0.0
        for mirrorX in [true, false] {
            // Rückseite spiegeln: um die Längsachse gewendet → links/rechts, um die Querachse → oben/unten
            var m = [Double](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                m[y * w + x] = mirrorX ? b[y * w + (w - 1 - x)] : b[(h - 1 - y) * w + x]
            } }
            // Versatz erst auf halbem Raster suchen, dann fein um den besten herum
            let coarseM = halved(m, width: w, height: h)
            var coarseBest = (value: -1.0, dx: 0, dy: 0)
            let r = maxShift / 2
            for dy in -r...r { for dx in -r...r {
                let c = correlation(coarseF, coarseM, width: w / 2, height: h / 2, dx: dx, dy: dy)
                if c > coarseBest.value { coarseBest = (c, dx, dy) }
            } }
            for dy in coarseBest.dy * 2 - 2...coarseBest.dy * 2 + 2 { for dx in coarseBest.dx * 2 - 2...coarseBest.dx * 2 + 2 {
                best = max(best, correlation(f, m, width: w, height: h, dx: dx, dy: dy))
            } }
        }
        return best
    }

    /// Raster mit halber Auflösung (Mittel aus 2 × 2 Zellen).
    private static func halved(_ grid: [Double], width w: Int, height h: Int) -> [Double] {
        let hw = w / 2, hh = h / 2
        var result = [Double](repeating: 0, count: hw * hh)
        for y in 0..<hh { for x in 0..<hw {
            let i = 2 * y * w + 2 * x
            result[y * hw + x] = (grid[i] + grid[i + 1] + grid[i + w] + grid[i + w + 1]) / 4
        } }
        return result
    }

    /// Pearson-Korrelation von `a` mit dem um (dx, dy) verschobenen `b` auf der Überlappung.
    private static func correlation(_ a: [Double], _ b: [Double], width w: Int, height h: Int, dx: Int, dy: Int) -> Double {
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for y in max(0, -dy)..<min(h, h - dy) {
                    let rowA = y * w, rowB = (y + dy) * w + dx
                    for x in max(0, -dx)..<min(w, w - dx) {
                        let va = a[rowA + x], vb = b[rowB + x]
                        n += 1; sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb
                    }
                }
            }
        }
        guard n > 0 else { return 0 }
        let cov = sab - sa * sb / n, varA = saa - sa * sa / n, varB = sbb - sb * sb / n
        guard varA > 0, varB > 0 else { return 0 }
        return cov / (varA * varB).squareRoot()
    }

    /// Druckdichte (0 = weiß … 255 = schwarz) auf festem Raster, ohne Ränder (Scannerschatten, Lochung).
    private static func inkGrid(_ image: CGImage, width w: Int, height h: Int) -> [Double]? {
        let small = ImageTools.downscaled(image, maxPixel: max(w, h) * 3)
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let mx = Int(Double(w) * 0.06), my = Int(Double(h) * 0.04)
        return pixels.enumerated().map { i, v in
            let x = i % w, y = i / w
            return x < mx || x >= w - mx || y < my || y >= h - my ? 0 : Double(255 - Int(v))
        }
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
