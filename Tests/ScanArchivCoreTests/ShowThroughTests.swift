import AppKit
import CoreGraphics
import Foundation
@testable import ScanArchivCore
import Testing

@Suite("Durchscheinende Vorderseite")
struct ShowThroughTests {
    static let width = 2480, height = 3508

    /// Briefseite (A4, 300 dpi) mit Briefkopf, Anschrift und Fließtext; `seed` bestimmt die Wortlängen.
    static func letter(seed: UInt64, gray: CGFloat = 0) -> CGImage {
        let ctx = context()
        draw(letterIn: ctx, seed: seed, gray: gray)
        return ctx.makeImage()!
    }

    static func context() -> CGContext {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    static func draw(letterIn ctx: CGContext, seed: UInt64, gray: CGFloat) {
        var state = seed
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        func text(_ s: String, x: Int, y: Int, size: CGFloat, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: NSColor(white: gray, alpha: 1)]))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        let words = ["Versicherung", "Angebot", "Beitrag", "monatlich", "und", "die", "Sie", "Vertrag", "zum", "Rente",
                     "Leistung", "gemäß", "Ihrer", "Anfrage", "wir", "freuen", "uns", "Kasse", "Betrag", "Euro"]
        text(["Allianz", "Stadtwerke", "Finanzamt"][next(3)] + " Gruppe", x: 1500 + next(200), y: 3250, size: 90, bold: true)
        text("Herrn Max Mustermann", x: 250, y: 2750, size: 42)
        text("Gartenweg \(next(90) + 1)", x: 250, y: 2690, size: 42)
        text("54321 Beispielort", x: 250, y: 2630, size: 42)
        text("\(next(28) + 1).09.2026", x: 1800, y: 2400, size: 42)
        text("Betreff: " + words[next(words.count)] + " " + words[next(words.count)], x: 250, y: 2250, size: 46, bold: true)
        var y = 2100
        while y > 500 {
            var line = ""
            while line.count < 60 + next(15) { line += words[next(words.count)] + " " }
            if next(8) == 0 { y -= 60 }  // Absatz
            text(line, x: 250, y: y, size: 42)
            y -= 62
        }
    }

    /// Wie die Rückseite im Scanner aussieht, wenn nur die Vorderseite durchscheint:
    /// gespiegelt, blass, unscharf und leicht versetzt.
    static func showThrough(of front: CGImage, mirrorX: Bool = true, strength: CGFloat = 0.25, shift: Int = 25,
                            skew: CGFloat = 0.6) -> CGImage {
        let small = ImageTools.downscaled(front, maxPixel: 700)  // Unschärfe durchs Papier
        let ctx = context()
        ctx.interpolationQuality = .high
        ctx.setAlpha(strength)
        // leicht schräg eingezogen
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: skew * .pi / 180)
        ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        ctx.translateBy(x: mirrorX ? CGFloat(width) : 0, y: mirrorX ? 0 : CGFloat(height))
        ctx.scaleBy(x: mirrorX ? -1 : 1, y: mirrorX ? 1 : -1)
        ctx.draw(small, in: CGRect(x: shift, y: -shift, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test("Gespiegelter Durchschein wird erkannt (Stapel längs oder quer gewendet)", arguments: [true, false])
    func detected(mirrorX: Bool) {
        let front = Self.letter(seed: 1)
        let back = Self.showThrough(of: front, mirrorX: mirrorX)
        #expect(BlankPage.isShowThrough(back, front: front), "Korrelation \(BlankPage.showThroughCorrelation(back, front: front))")
    }

    @Test("Kräftiger Durchschein (dünnes Papier) wird erkannt")
    func strongShowThrough() {
        let front = Self.letter(seed: 2)
        let back = Self.showThrough(of: front, strength: 0.6, shift: -40)
        #expect(BlankPage.isShowThrough(back, front: front), "Korrelation \(BlankPage.showThroughCorrelation(back, front: front))")
    }

    @Test("Echte Rückseite ist kein Durchschein")
    func realBackPage() {
        let front = Self.letter(seed: 3)
        let back = Self.letter(seed: 4)
        #expect(!BlankPage.isShowThrough(back, front: front), "Korrelation \(BlankPage.showThroughCorrelation(back, front: front))")
        // auch nicht, wenn ein wenig von der Vorderseite durchscheint
        let ctx = Self.context()
        ctx.draw(Self.showThrough(of: front), in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        ctx.setBlendMode(.multiply)
        ctx.draw(back, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let mixed = ctx.makeImage()!
        #expect(!BlankPage.isShowThrough(mixed, front: front), "Korrelation \(BlankPage.showThroughCorrelation(mixed, front: front))")
    }

    @Test("Leere Rückseite und leere Vorderseite")
    func blankPages() {
        let front = Self.letter(seed: 5)
        let white = Self.context().makeImage()!
        #expect(!BlankPage.isShowThrough(white, front: front))
        #expect(!BlankPage.isShowThrough(Self.showThrough(of: front), front: white))
    }
}
