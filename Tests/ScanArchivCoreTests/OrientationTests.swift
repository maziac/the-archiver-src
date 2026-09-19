import CoreGraphics
import CoreText
import Foundation
@testable import ScanArchivCore
import Testing

@Suite("Seitenausrichtung")
struct OrientationTests {
    /// A4-Seite (150 dpi) mit einem Brieftext, aufrecht.
    static func letterPage() -> CGImage {
        let width = 1240, height = 1754
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let lines = [
            "Stadtwerke Musterstadt GmbH", "Postfach 1234, 12345 Musterstadt", "",
            "Herrn Thomas Beispiel", "Hauptstraße 5", "54321 Beispielort", "",
            "Musterstadt, 11. Dezember 2025", "",
            "Jahresabrechnung Strom 2025",
            "Sehr geehrter Herr Beispiel,",
            "anbei erhalten Sie die Abrechnung für den Zeitraum vom",
            "1. Januar bis 31. Dezember 2025. Ihr Verbrauch betrug",
            "insgesamt 2.845 Kilowattstunden. Nach Abzug der geleisteten",
            "Abschlagszahlungen ergibt sich ein Guthaben von 84,20 Euro,",
            "das wir Ihrem Konto in den nächsten Tagen gutschreiben.",
            "Mit freundlichen Grüßen", "Ihre Stadtwerke",
        ]
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        var y = Double(height) - 160
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            ctx.textPosition = CGPoint(x: 120, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            y -= 48
        }
        return ctx.makeImage()!
    }

    @Test("Rotation um 90° dreht im Uhrzeigersinn")
    func rotationDirection() {
        // 20×10-Bild: links schwarz, rechts weiß → nach 90° im Uhrzeigersinn oben schwarz, unten weiß
        let ctx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let image = ctx.makeImage()!
        let cw = ImageTools.rotated(image, clockwise: 90)
        #expect(cw.width == 10 && cw.height == 20)
        let data = cw.dataProvider!.data! as Data
        #expect(data[0] < 128)  // erste Zeile = oben
        #expect(data[cw.bytesPerRow * 19] > 128)
        let ccw = ImageTools.rotated(image, clockwise: 270)
        let ccwData = ccw.dataProvider!.data! as Data
        #expect(ccwData[0] > 128 && ccwData[ccw.bytesPerRow * 19] < 128)
    }

    @Test("Gedrehte Seiten werden erkannt", arguments: [0, 90, 180, 270])
    func detectsRotation(turned: Int) async {
        // Seite um `turned` gedreht → zum Aufrichten muss sie um (360 - turned) zurück
        let page = ImageTools.rotated(Self.letterPage(), clockwise: turned)
        let scores = await OCRService.orientationScores(page)
        #expect(OCRService.decideOrientation(scores) == (360 - turned) % 360)
    }

    @Test("Leere Seite: keine Entscheidung")
    func blankPage() async {
        let ctx = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(await OCRService.detectOrientation(ctx.makeImage()!) == nil)
    }
}
