import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct PDFStamperTests {
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 18, hour: 12).date!

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stamper-\(UUID().uuidString).pdf")
    }

    /// PDF mit echtem (Vektor-)Text und einem Link.
    func makeTextPDF() -> URL {
        let url = tempURL()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in ["Online-Rechnung Telekom Betrag 49,95 EUR", "Seite zwei mit Einzelverbindungsnachweis"] {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            ctx.textPosition = CGPoint(x: 60, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let doc = PDFDocument(url: url)!
        let link = PDFAnnotation(bounds: CGRect(x: 60, y: 690, width: 200, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        doc.page(at: 0)!.addAnnotation(link)
        doc.write(to: url)
        return url
    }

    /// PDF, das nur ein Bild enthält (wie ein Scan ohne OCR), optional mit /Rotate.
    func makeImagePDF(rotation: Int = 0) -> URL {
        let url = tempURL()
        let image = PDFBuilderTests.renderPage("Mahnung Finanzamt")  // Text oben links
        var box = CGRect(x: 0, y: 0, width: 595.2, height: 841.9)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        if rotation != 0 {
            let doc = PDFDocument(url: url)!
            doc.page(at: 0)!.rotation = rotation
            doc.write(to: url)
        }
        return url
    }

    @Test func detectsTextPages() {
        #expect(PDFStamper.pageTexts(of: makeTextPDF()).allSatisfy { !$0.isEmpty })
        #expect(PDFStamper.pageTexts(of: makeImagePDF()) == [""])
    }

    @Test func textPDFKeepsContentAndGetsStamp() throws {
        let source = makeTextPDF()
        let data = try PDFStamper.stamp(source: source, pages: [.init(index: 0), .init(index: 1)], number: 42, date: date,
                                        title: "Telekom Rechnung", summary: "Mobilfunk")
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("Online-Rechnung Telekom") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000042") == true)
        #expect(pdf.page(at: 1)?.string?.contains("000042") == false)
        #expect(pdf.page(at: 0)?.annotations.contains { $0.url?.absoluteString == "https://example.com" } == true)
        let attrs = pdf.documentAttributes ?? [:]
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "Telekom Rechnung")
        #expect((attrs[PDFDocumentAttribute.keywordsAttribute] as? [String])?.contains("000042") == true)
    }

    @Test func removedAndReorderedPages() throws {
        let data = try PDFStamper.stamp(source: makeTextPDF(), pages: [.init(index: 1)], number: 1, date: date, title: "", summary: "")
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
        #expect(pdf.page(at: 0)?.string?.contains("Einzelverbindungsnachweis") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)
    }

    /// OCR auf der gerenderten Seite, Textebene zurück ins Original – für 0°, 90°, 180° und 270°.
    @Test(arguments: [0, 90, 180, 270])
    func imagePDFGetsPositionedOCRLayer(rotation: Int) async throws {
        let source = makeImagePDF(rotation: rotation)
        let cg = try #require(CGPDFDocument(source as CFURL))
        // Seite so rendern, wie sie angezeigt wird; bei 180° zusätzlich zurückdrehen, damit der Text aufrecht ist
        let extra = rotation == 0 ? 0 : 360 - rotation
        let image = try #require(ImageTools.renderPDFPage(cg, index: 0, dpi: 150, gray: true, extraRotation: extra))
        let lines = try await OCRService.recognize(image)
        #expect(lines.map(\.text).joined().contains("Mahnung"))

        let data = try PDFStamper.stamp(source: source, pages: [.init(index: 0, extraRotation: extra, lines: lines)],
                                        number: 7, date: date, title: "", summary: "")
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        #expect(page.rotation == 0)
        let text = page.string ?? ""
        #expect(text.contains("Mahnung Finanzamt"))
        // Text liegt oben links, der Stempel oben rechts (im unveränderten Seitenraum, da Drehung wieder 0)
        let selection = try #require(pdf.findString("Mahnung", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        #expect(bounds.minX < 150 && bounds.minY > 550, "Mahnung bei \(bounds)")
        let stamp = try #require(pdf.findString("Nr. 000007", withOptions: []).first).bounds(for: page)
        #expect(stamp.minX > 400 && stamp.minY > 780, "Stempel bei \(stamp)")
    }

    @Test func originalImageResolutionIsKept() throws {
        let source = makeImagePDF()
        let before = try Data(contentsOf: source).count
        let data = try PDFStamper.stamp(source: source, pages: [.init(index: 0)], number: 1, date: date, title: "", summary: "")
        // gleiche Bilddaten, nur Stempel/Metadaten dazu
        #expect(abs(data.count - before) < 20_000, "vorher \(before), nachher \(data.count)")
    }
}
