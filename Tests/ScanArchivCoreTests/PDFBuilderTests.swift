import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct PDFBuilderTests {
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 18, hour: 12).date!

    /// Weiße A4-Seite bei 150 dpi mit gerendertem Text.
    static func renderPage(_ text: String) -> CGImage {
        let width = 1240, height = 1754
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 60, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        ctx.textPosition = CGPoint(x: 120, y: 1400)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    @Test func ocrFindsText() throws {
        let lines = try OCRService.recognize(Self.renderPage("Stromrechnung Oktober"))
        let text = lines.map(\.text).joined(separator: " ")
        #expect(text.contains("Stromrechnung"))
    }

    @Test func pdfIsSearchableAndStamped() throws {
        let images = [Self.renderPage("Stromrechnung Oktober"), Self.renderPage("Zahlungsbedingungen")]
        let pages = try images.map { PDFPageInput(image: $0, lines: try OCRService.recognize($0)) }
        let data = try PDFBuilder.build(pages: pages, number: 123, date: date, dpi: 150)

        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        // A4 bei 150 dpi → ca. 595 × 842 pt
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595.2) < 1)

        let page1 = pdf.page(at: 0)?.string ?? ""
        #expect(page1.contains("Stromrechnung"))
        #expect(page1.contains("Nr. 000123"))
        #expect(pdf.page(at: 1)?.string?.contains("Zahlungsbedingungen") == true)
        #expect(pdf.page(at: 1)?.string?.contains("000123") == false)

        let attrs = pdf.documentAttributes ?? [:]
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "2026-09-18_000123")
        #expect((attrs[PDFDocumentAttribute.keywordsAttribute] as? [String])?.contains("000123") == true)
        // JPEG-Einbettung hält die Datei klein
        #expect(data.count < 500_000)
    }

    @Test func rotate180() {
        let image = Self.renderPage("X")
        let rotated = ImageTools.rotated180(image)
        #expect(rotated.width == image.width && rotated.height == image.height)
    }
}
