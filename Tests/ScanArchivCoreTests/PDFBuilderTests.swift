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

    @Test func ocrFindsText() async throws {
        let lines = try await OCRService.recognize(Self.renderPage("Stromrechnung Oktober"))
        let text = lines.map(\.text).joined(separator: " ")
        #expect(text.contains("Stromrechnung"))
    }

    @Test func pdfIsSearchableAndStamped() async throws {
        let images = [Self.renderPage("Stromrechnung Oktober"), Self.renderPage("Zahlungsbedingungen")]
        var pages: [PDFPageInput] = []
        for image in images { pages.append(PDFPageInput(image: image, lines: try await OCRService.recognize(image))) }
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

    @Test func renderImportedPDF() async throws {
        let data = try PDFBuilder.build(pages: [PDFPageInput(image: Self.renderPage("Mietvertrag"), lines: [])], number: 5, date: date, dpi: 150)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).pdf")
        try data.write(to: url)
        let images = ImageTools.renderPDF(url, dpi: 150, gray: true)
        #expect(images.count == 1)
        #expect(abs(images[0].width - 1240) <= 1)
        let text = try await OCRService.recognize(images[0]).map(\.text).joined(separator: " ")
        #expect(text.contains("Mietvertrag"))
    }

    @Test func perPageDPI() throws {
        let page = PDFPageInput(image: Self.renderPage("X"), lines: [], dpi: 300)
        let pdf = try #require(PDFDocument(data: try PDFBuilder.build(pages: [page], number: 1, date: date, dpi: 150)))
        #expect(abs(pdf.page(at: 0)!.bounds(for: .mediaBox).width - 297.6) < 1)
    }

    static let wordLine = "Sehr geehrter Herr Mustermann, Ihren Antrag."

    /// `wordLine` in einer Schrift, die anders läuft als Helvetica (Courier), auf einer A4-Seite bei 150 dpi.
    /// Liefert das Bild und die tatsächliche Lage eines Teilstücks in Punkt (Ursprung unten links).
    static func renderWordLine() -> (CGImage, (String) -> ClosedRange<CGFloat>) {
        let width = 1240, height = 1754, scale = 72.0 / 150
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Courier" as CFString, 34, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: wordLine, attributes: [.font: font, .foregroundColor: NSColor.black]))
        let origin = CGPoint(x: 100, y: 1400)
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        let span = { (part: String) -> ClosedRange<CGFloat> in
            let range = (wordLine as NSString).range(of: part)
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            return (origin.x + start) * scale...(origin.x + end) * scale
        }
        return (ctx.makeImage()!, span)
    }

    /// Suchtreffer werden auf dem Wort im Bild markiert – nicht nur irgendwo in der richtigen Zeile.
    static func expectWordPositions(_ data: Data, _ span: (String) -> ClosedRange<CGFloat>) throws {
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        #expect(page.string?.contains(wordLine) == true)
        // („Mustermann,“ nicht: innerhalb eines Wortes verteilen sich die Zeichen nach Helvetica-Breiten,
        // und das Komma ist in Courier viel breiter)
        for word in ["Sehr", "geehrter", "Herr", "Ihren", "Antrag"] {
            let found = try #require(pdf.findString(word, withOptions: []).first).bounds(for: page)
            let expected = span(word)
            // Toleranz: Vision lässt um jedes Wort ein paar Punkt Rand
            #expect(abs(found.minX - expected.lowerBound) < 6 && abs(found.maxX - expected.upperBound) < 6,
                    "\(word): \(found.minX)…\(found.maxX) statt \(expected)")
        }
    }

    @Test func textLayerMatchesWordPositions() async throws {
        let (image, span) = Self.renderWordLine()
        let lines = try await OCRService.recognize(image)
        let data = try PDFBuilder.build(pages: [PDFPageInput(image: image, lines: lines)], number: 1, date: date, dpi: 150)
        try Self.expectWordPositions(data, span)
    }

    @Test func appendedTextLayerMatchesWordPositions() async throws {
        let (image, span) = Self.renderWordLine()
        let lines = try await OCRService.recognize(image)
        let original = try PDFBuilder.build(pages: [PDFPageInput(image: image, lines: [])], number: 1, date: date, dpi: 150, stamp: false)
        let meta = DocumentMetadata(number: 1, documentDate: date, dateSource: .ai, titleSource: .ai, archivedAt: date, source: .pdf,
                                    originalFileName: "a.pdf", pages: [.ocr], storage: .appended)
        let data = try PDFAppender.stamp(original: original, stampText: "Nr. 000001", overlays: [.init(pageIndex: 0, lines: lines)],
                                         meta: meta, title: "", summary: "")
        try Self.expectWordPositions(data, span)
    }
}
