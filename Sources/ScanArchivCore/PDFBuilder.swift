import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PDFBuilderError: LocalizedError {
    case contextCreationFailed
    case jpegEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed: return "PDF konnte nicht erzeugt werden."
        case .jpegEncodingFailed: return "Seitenbild konnte nicht komprimiert werden."
        }
    }
}

/// Eine fertig ausgerichtete Seite mit ihrem OCR-Ergebnis.
public struct PDFPageInput {
    public enum Content {
        /// Seitenbild, wird unverändert gezeichnet (vorher mit `PageCompressor` kodieren);
        /// dpi nil = die Auflösung aus `build(dpi:)`
        case image(CGImage, dpi: Double?)
        /// Seite eines vorhandenen PDFs, unverändert als Vektor übernommen (eigener Text bleibt erhalten)
        case vector(CGPDFPage)
    }

    public var content: Content
    /// unsichtbare Textebene (nur für Bildseiten)
    public var lines: [OCRLine]

    public init(image: CGImage, lines: [OCRLine], dpi: Double? = nil) {
        content = .image(image, dpi: dpi)
        self.lines = lines
    }

    public init(encoded: EncodedImage, lines: [OCRLine]) {
        content = .image(encoded.image, dpi: encoded.dpi)
        self.lines = lines
    }

    public init(vectorPage: CGPDFPage) {
        content = .vector(vectorPage)
        lines = []
    }
}

public enum PDFBuilder {
    /// Stempeltext für Seite 1, z. B. "Nr. 000123 · 18.09.2026".
    public static func stampText(number: Int, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return "Nr. \(Archive.formatNumber(number)) · \(f.string(from: date))"
    }

    /// Baut ein durchsuchbares PDF: Seitenbild bzw. Vektor-Seite + unsichtbare OCR-Textebene je Seite,
    /// sichtbarer Nummernstempel auf Seite 1 und Standard-Metadaten (Titel, Beschreibung, Keywords).
    /// Die Bilder werden so eingebettet, wie sie übergeben werden (Kompression vorher per `PageCompressor`).
    public static func build(pages: [PDFPageInput], number: Int, date: Date, dpi: Double,
                             title: String = "", summary: String = "") throws -> Data {
        let data = NSMutableData()
        let numberText = Archive.formatNumber(number)
        let fallbackTitle = Archive.fileName(date: date, number: number).replacingOccurrences(of: ".pdf", with: "")
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title.isEmpty ? fallbackTitle : title,
            kCGPDFContextSubject: summary.isEmpty ? stampText(number: number, date: date) : summary,
            kCGPDFContextKeywords: [numberText, "Nr. \(numberText)"] as CFArray,
            kCGPDFContextCreator: "ScanArchiv",
        ]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else {
            throw PDFBuilderError.contextCreationFailed
        }

        for (index, page) in pages.enumerated() {
            let size: CGSize
            switch page.content {
            case let .image(image, pageDPI):
                let d = pageDPI ?? dpi
                size = CGSize(width: Double(image.width) / d * 72, height: Double(image.height) / d * 72)
            case let .vector(pdfPage):
                let box = pdfPage.getBoxRect(.cropBox)
                size = Int(pdfPage.rotationAngle) % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            }
            var mediaBox = CGRect(origin: .zero, size: size)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)

            switch page.content {
            case let .image(image, _):
                ctx.draw(image, in: mediaBox)
            case let .vector(pdfPage):
                ctx.saveGState()
                let box = pdfPage.getBoxRect(.cropBox)
                let (toPage, _) = PDFStamper.displayToPage(rotation: Int(pdfPage.rotationAngle), box: box)
                ctx.concatenate(toPage.inverted())
                ctx.clip(to: box)
                ctx.drawPDFPage(pdfPage)
                ctx.restoreGState()
            }
            drawInvisibleText(page.lines, in: ctx, pageSize: size)
            if index == 0 {
                drawStamp(stampText(number: number, date: date), in: ctx, pageSize: size)
            }

            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func drawInvisibleText(_ lines: [OCRLine], in ctx: CGContext, pageSize: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                              width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            drawInvisible(line.text, in: rect, ctx: ctx)
        }
        ctx.restoreGState()
    }

    /// Unsichtbarer Text in der Schrift ohne Zeichenformen, horizontal auf `rect` gestreckt
    /// (damit Markieren im Viewer zur sichtbaren Schrift passt). Aufrufer setzt den Zeichenmodus.
    private static func drawInvisible(_ text: String, in rect: CGRect, ctx: CGContext) {
        func line(size: CGFloat) -> (CTLine, CGFloat) {
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): GlyphlessFont.font(size: size)]))
            return (l, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)))
        }
        var (ctLine, textWidth) = line(size: rect.height * 0.85)
        guard textWidth > 0 else { return }
        // Zu schmale Zeile: Schrift verkleinern statt stauchen – gestauchter Text wird von PDFKit
        // sonst mit Leerzeichen zwischen den Buchstaben ausgelesen („E U R O …“).
        if rect.width < textWidth * 0.95 {
            (ctLine, textWidth) = line(size: rect.height * 0.85 * rect.width / textWidth)
            guard textWidth > 0 else { return }
        }
        ctx.textMatrix = CGAffineTransform(scaleX: rect.width / textWidth, y: 1)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
        CTLineDraw(ctLine, ctx)
    }

    /// Roter Nummernstempel (echter Text, damit die Nummer im PDF durchsuchbar ist).
    static func drawStamp(_ text: String, in ctx: CGContext, pageSize: CGSize) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 9, nil)
        // Rot, damit er sich vom schwarz-weißen Scan abhebt
        let color = CGColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1)
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let margin: CGFloat = 14, padding: CGFloat = 3
        let origin = CGPoint(x: pageSize.width - margin - width, y: pageSize.height - margin - ascent)

        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        let box = CGRect(x: origin.x - padding, y: origin.y - descent - padding,
                         width: width + 2 * padding, height: ascent + descent + 2 * padding)
        ctx.fill(box)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(0.75)
        ctx.stroke(box)
        ctx.textMatrix = .identity
        ctx.setTextDrawingMode(.fill)
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

public enum ImageTools {
    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func thumbnail(_ url: URL, maxPixel: Int = 400) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Auflösung eines importierten Bildes: aus den Bild-Metadaten, sonst so, dass die Breite
    /// einer A4-Seite (8,27") entspricht.
    public static func dpi(of url: URL, width: Int) -> Double {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi >= 100 {
            return dpi
        }
        return max(Double(width) / 8.27, 72)
    }

    /// Rendert alle Seiten eines PDFs als Bitmap (weißer Hintergrund) mit der gegebenen Auflösung.
    public static func renderPDF(_ url: URL, dpi: Double, gray: Bool) -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        return (0..<document.numberOfPages).compactMap { renderPDFPage(document, index: $0, dpi: dpi, gray: gray) }
    }

    /// Rendert eine Seite (Index ab 0) so, wie sie angezeigt wird: Seitendrehung plus `extraRotation` (Uhrzeigersinn).
    public static func renderPDFPage(_ document: CGPDFDocument, index: Int, dpi: Double, gray: Bool, extraRotation: Int = 0) -> CGImage? {
        guard let page = document.page(at: index + 1) else { return nil }
        let rotation = ((Int(page.rotationAngle) + extraRotation) % 360 + 360) % 360
        let box = page.getBoxRect(.cropBox)
        let size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = dpi / 72
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        // Seitenraum → angezeigte Seite (gleiche Abbildung wie beim Überlagern der Textebene)
        let (toPage, _) = PDFStamper.displayToPage(rotation: rotation, box: box)
        ctx.concatenate(toPage.inverted())
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PDFBuilderError.jpegEncodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PDFBuilderError.jpegEncodingFailed }
    }

    public static func rotated180(_ image: CGImage) -> CGImage {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let isGray = colorSpace.model == .monochrome
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
        ctx.rotate(by: .pi)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
