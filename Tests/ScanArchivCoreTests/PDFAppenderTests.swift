import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct PDFAppenderTests {
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 19, hour: 12).date!
    let helpers = PDFStamperTests()

    func meta(_ number: Int, pages: [DocumentMetadata.TextSource]) -> DocumentMetadata {
        DocumentMetadata(number: number, documentDate: date, dateSource: .ai, titleSource: .ai, archivedAt: date, source: .pdf,
                         originalFileName: "Änderung „Test“.pdf", pages: pages, storage: .appended)
    }

    /// Von Hand gebautes PDF 1.5 mit Objekt-Stream und komprimiertem Querverweis-Stream (PNG-Prädiktor „Up“),
    /// wie es viele Scan-/Office-Programme erzeugen.
    static func makeObjectStreamPDF() -> Data {
        var pdf = Data("%PDF-1.5\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        let content = "BT /F1 18 Tf 60 700 Td (Hallo Welt Objektstream) Tj ET"
        let o4 = pdf.count
        pdf.append(Data("4 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n".utf8))
        let objects = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> >>"),
            (3, "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>"),
            (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ]
        var body = "", header = ""
        for (num, text) in objects {
            header += "\(num) \(body.utf8.count) "
            body += text + "\n"
        }
        let stm = PDFRawDocument.deflate(Array((header + body).utf8))
        let o6 = pdf.count
        pdf.append(Data("6 0 obj\n<< /Type /ObjStm /N 4 /First \(header.utf8.count) /Filter /FlateDecode /Length \(stm.count) >>\nstream\n".utf8))
        pdf.append(contentsOf: stm)
        pdf.append(Data("\nendstream\nendobj\n".utf8))
        let o7 = pdf.count
        // Zeilen: Typ(1) Feld2(4) Feld3(2)
        let rows: [(Int, Int, Int)] = [(0, 0, 65535), (2, 6, 0), (2, 6, 1), (2, 6, 2), (1, o4, 0), (2, 6, 3), (1, o6, 0), (1, o7, 0)]
        var raw: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: 7)
        for (t, f2, f3) in rows {
            let row: [UInt8] = [UInt8(t), UInt8(f2 >> 24 & 0xFF), UInt8(f2 >> 16 & 0xFF), UInt8(f2 >> 8 & 0xFF), UInt8(f2 & 0xFF),
                                UInt8(f3 >> 8 & 0xFF), UInt8(f3 & 0xFF)]
            raw.append(2)  // PNG „Up“
            raw += zip(row, previous).map { $0 &- $1 }
            previous = row
        }
        let xref = PDFRawDocument.deflate(raw)
        pdf.append(Data("7 0 obj\n<< /Type /XRef /Size 8 /W [1 4 2] /Root 1 0 R /Filter /FlateDecode /DecodeParms << /Columns 7 /Predictor 12 >> /Length \(xref.count) >>\nstream\n".utf8))
        pdf.append(contentsOf: xref)
        pdf.append(Data("\nendstream\nendobj\nstartxref\n\(o7)\n%%EOF\n".utf8))
        return pdf
    }

    @Test func parsesObjectAndXRefStreams() throws {
        let data = Self.makeObjectStreamPDF()
        #expect(PDFDocument(data: data)?.string?.contains("Hallo Welt Objektstream") == true)  // Testdatei selbst gültig
        let doc = try PDFRawDocument(data: data)
        #expect(doc.usesXRefStream)
        let pages = try doc.pages()
        #expect(pages.count == 1)
        #expect(pages[0].inherited["MediaBox"] != nil)
        #expect(try doc.object(5).dict?["BaseFont"] == .name("Helvetica"))
    }

    @Test func appendsToObjectStreamPDF() throws {
        let original = Self.makeObjectStreamPDF()
        let stamped = try PDFAppender.stamp(original: original, stampText: PDFBuilder.stampText(number: 7, date: date), overlays: [],
                                            meta: meta(7, pages: [.embedded]), title: "Titel Ä", summary: "Beschreibung")
        #expect(stamped.prefix(original.count) == original)  // Original bitgenau erhalten
        #expect(stamped.count - original.count < 4_000, "\(stamped.count - original.count) Bytes angehängt")
        let pdf = try #require(PDFDocument(data: stamped))
        #expect(pdf.page(at: 0)?.string?.contains("Hallo Welt Objektstream") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000007 · 19.09.2026") == true)
        #expect(PDFMetadata.read(pdf) == meta(7, pages: [.embedded]))
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Titel Ä")

        // weitere Änderung hängt nur wenig an und ersetzt die Metadaten-Anmerkung
        var changed = meta(7, pages: [.embedded])
        changed.titleSource = .manual
        let updated = try PDFAppender.updateMetadata(stamped, meta: changed, title: "Neu", summary: "")
        #expect(updated.prefix(stamped.count) == stamped)
        #expect(updated.count - stamped.count < 2_000)
        let reread = try #require(PDFDocument(data: updated))
        #expect(PDFMetadata.read(reread)?.titleSource == .manual)
        #expect(reread.page(at: 0)?.annotations.count == 1)
    }

    @Test func keepsLinksAndText() throws {
        let original = try Data(contentsOf: helpers.makeTextPDF())
        let stamped = try PDFAppender.stamp(original: original, stampText: PDFBuilder.stampText(number: 3, date: date), overlays: [],
                                            meta: meta(3, pages: [.embedded, .embedded]), title: "", summary: "")
        let pdf = try #require(PDFDocument(data: stamped))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.annotations.contains { $0.url?.absoluteString == "https://example.com" } == true)
        #expect(pdf.page(at: 1)?.string?.contains("Einzelverbindungsnachweis") == true)
        #expect(pdf.page(at: 1)?.string?.contains("000003") == false)
    }

    /// Gedrehte Bildseite: OCR-Ebene liegt über dem Bildtext, Stempel an der angezeigten oberen rechten Ecke.
    @Test func rotatedImagePageGetsOverlay() async throws {
        let url = helpers.makeImagePDF(rotation: 180)
        let cg = try #require(CGPDFDocument(url as CFURL))
        let image = try #require(ImageTools.renderPDFPage(cg, index: 0, dpi: 150, gray: true))
        let lines = try await OCRService.recognize(image)
        let stamped = try PDFAppender.stamp(original: try Data(contentsOf: url), stampText: PDFBuilder.stampText(number: 9, date: date),
                                            overlays: [.init(pageIndex: 0, lines: lines)], meta: meta(9, pages: [.ocr]),
                                            title: "", summary: "")
        let pdf = try #require(PDFDocument(data: stamped))
        let page = try #require(pdf.page(at: 0))
        #expect(page.rotation == 180)
        #expect(page.string?.contains("Mahnung Finanzamt") == true)
        // Textebene liegt im Bereich der Bildzeile (im Seitenraum oben, x ≈ 60…330) – wie beim PDFKit-Weg
        let text = try #require(pdf.findString("Mahnung", withOptions: []).first).bounds(for: page)
        #expect(text.minX > 50 && text.maxX < 345 && text.minY > 640, "Text bei \(text)")
        // Stempel an der angezeigten oberen rechten Ecke = im Seitenraum unten links
        let stamp = try #require(pdf.findString("Nr. 000009", withOptions: []).first).bounds(for: page)
        #expect(stamp.maxX < 200 && stamp.maxY < 60, "Stempel bei \(stamp)")
        // nur die benutzten Zeichen der leeren Schrift eingebettet
        #expect(stamped.count - (try Data(contentsOf: url)).count < 8_000)
    }

    @Test func importPrefersAppendedAndKeepsOriginalBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Append-\(UUID().uuidString)")
        let archive = try Archive(folder: folder)
        let index = try SearchIndex(url: folder.appendingPathComponent(SearchIndex.fileName))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("objstm-\(UUID().uuidString).pdf")
        try Self.makeObjectStreamPDF().write(to: source)
        let result = try await ImportProcessor.process(file: source, archive: archive, index: index,
                                                       options: ImportOptions(useSummarizer: false))
        let stored = try Data(contentsOf: result.url)
        let original = try Data(contentsOf: source)
        #expect(result.meta.storage == .appended)
        #expect(stored.prefix(original.count) == original)
        #expect(PDFMetadata.read(url: result.url)?.storage == .appended)

        // Bearbeiten hängt ebenfalls nur an
        let edited = try archive.updateMetadata(url: result.url, date: date, title: "Bearbeitet", summary: "") { $0.titleSource = .manual }
        let after = try Data(contentsOf: edited.url)
        #expect(after.prefix(stored.count) == stored)
        #expect(PDFMetadata.read(url: edited.url)?.storage == .appended)
    }
}
