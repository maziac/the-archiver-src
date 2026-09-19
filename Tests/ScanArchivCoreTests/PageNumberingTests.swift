import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

@Suite("Seitenreihenfolge")
struct PageNumberingTests {
    /// Seite mit Brieftext und Fußzeile
    static func page(_ body: String, footer: String) -> String {
        (["Stadtwerke Musterstadt", body, "Lorem ipsum dolor sit amet", "consectetur adipiscing elit"] + [footer]).joined(separator: "\n")
    }

    @Test("Muster werden erkannt", arguments: [
        ("Seite 2 von 4", 2, 4), ("Seite 3/5", 3, 5), ("Page 3 of 4", 3, 4), ("- 2 -", 2, nil),
        ("– 7 –", 7, nil), ("2/4", 2, 4), ("Blatt 2", 2, nil), ("S. 12", 12, nil), ("Kundennr. 123 · Seite 2", 2, nil), ("Seite: 4 von 5", 4, 5),
    ] as [(String, Int, Int?)])
    func patterns(footer: String, number: Int, total: Int?) {
        #expect(PageNumbering.pageNumber(in: Self.page("Text", footer: footer)) == .init(number: number, total: total))
    }

    @Test("Nackte Zahlen und Beträge zählen nicht")
    func noBareNumbers() {
        #expect(PageNumbering.pageNumber(in: Self.page("Text", footer: "2")) == nil)
        #expect(PageNumbering.pageNumber(in: Self.page("Text", footer: "Summe 84,20 EUR")) == nil)
        #expect(PageNumbering.pageNumber(in: Self.page("Text", footer: "12345 Musterstadt")) == nil)
        // mitten im Text (nicht Kopf/Fuß) zählt nicht
        let long = (["Kopf", "a", "b", "c", "d", "siehe Seite 5 unten"] + Array(repeating: "Zeile", count: 8)).joined(separator: "\n")
        #expect(PageNumbering.pageNumber(in: long) == nil)
    }

    @Test func inOrder() {
        let pages = (1...3).map { Self.page("Text \($0)", footer: "Seite \($0) von 3") }
        #expect(PageNumbering.analyze(pageTexts: pages) == .inOrder)
    }

    @Test func swappedPagesAreReordered() {
        let pages = [1, 3, 2, 4].map { Self.page("Text \($0)", footer: "Seite \($0) von 4") }
        #expect(PageNumbering.analyze(pageTexts: pages) == .reorder([0, 2, 1, 3]))
        #expect(PageNumbering.originalSequence([0, 2, 1, 3]) == [1, 3, 2, 4])
        #expect(PageNumbering.originalSequence([2, 0, 1]) == [2, 3, 1])
    }

    @Test("Duplex-Fehler: Rückseiten umgekehrt")
    func reversedBacks() {
        let pages = [1, 4, 3, 2].map { Self.page("Text", footer: "- \($0) -") }
        #expect(PageNumbering.analyze(pageTexts: pages) == .reorder([0, 3, 2, 1]))
    }

    @Test("Erste Seite ohne Nummer")
    func unnumberedFirstPage() {
        let pages = [Self.page("Anschreiben", footer: "Mit freundlichen Grüßen"),
                     Self.page("b", footer: "Seite 3"), Self.page("a", footer: "Seite 2")]
        #expect(PageNumbering.analyze(pageTexts: pages) == .reorder([0, 2, 1]))
        // unnummerierte Seite hinten kann eine Anlage sein: aufsteigend → nichts ändern, sonst nicht raten
        let appendix = [Self.page("b", footer: "Seite 2"), Self.page("c", footer: "Seite 3"), Self.page("Anlage", footer: "Gruß")]
        #expect(PageNumbering.analyze(pageTexts: appendix) == .inOrder)
        let unclear = [Self.page("c", footer: "Seite 3"), Self.page("b", footer: "Seite 2"), Self.page("Anlage", footer: "Gruß")]
        #expect(PageNumbering.analyze(pageTexts: unclear) == .uncertain([3, 2, nil]))
        // Lücke in der Mitte ist eindeutig
        let inner = [Self.page("a", footer: "Seite 1"), Self.page("?", footer: "x"), Self.page("d", footer: "Seite 4"), Self.page("c", footer: "Seite 3")]
        #expect(PageNumbering.analyze(pageTexts: inner) == .reorder([0, 1, 3, 2]))
    }

    @Test("Mehrdeutig: doppelte Nummern, zu viele Lücken")
    func uncertain() {
        let twoLetters = [1, 2, 1, 2].map { Self.page("Text", footer: "Seite \($0) von 2") }
        #expect(PageNumbering.analyze(pageTexts: twoLetters) == .uncertain([1, 2, 1, 2]))
        let gaps = [Self.page("a", footer: "Seite 3"), Self.page("b", footer: "x"), Self.page("c", footer: "y"), Self.page("d", footer: "Seite 1")]
        #expect(PageNumbering.analyze(pageTexts: gaps) == .uncertain([3, nil, nil, 1]))
    }

    @Test func noNumbers() {
        #expect(PageNumbering.analyze(pageTexts: ["a", "b", "c"]) == .none)
        #expect(PageNumbering.analyze(pageTexts: [Self.page("x", footer: "Seite 1")]) == .none)
    }

    @Test func severity() {
        #expect(DocumentIssue.noText(pages: [1]).severity == .error)
        #expect(DocumentIssue.noSuggestion("Fehler").severity == .error)
        #expect(DocumentIssue.noSuggestion(DocumentIssue.suggestionDisabled).severity == .warning)
        #expect(DocumentIssue.pageOrderCorrected(original: [1, 3, 2]).severity == .warning)
        #expect([DocumentIssue.pageOrderCorrected(original: [2, 1]), .noDate].maxSeverity == .error)
        #expect([DocumentIssue.pageOrderUncertain(numbers: [2, nil])].maxSeverity == .warning)
        #expect([DocumentIssue]().maxSeverity == nil)
        #expect(DocumentIssue.pageOrderUncertain(numbers: [3, nil, 1]).message.contains("3, ?, 1"))
    }

    // MARK: PDF

    /// Text-PDF: je Seite eine Überschrift und eine Fußzeile.
    static func makePDF(pages: [(title: String, footer: String)], size: CGSize = CGSize(width: 595, height: 842), to url: URL) {
        var box = CGRect(origin: .zero, size: size)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in pages {
            pdf.beginPDFPage(nil)
            for (text, y) in [(page.title, size.height - 100), ("Dies ist ein Beispieltext für die Seitenreihenfolge", size.height - 160), (page.footer, 40)] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 14)!]))
                pdf.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(line, pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    @Test("Import sortiert vertauschte Seiten um und vermerkt es gelb")
    func importReorders() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Reihenfolge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("vertauscht.pdf")
        Self.makePDF(pages: [("Erstens Anschreiben", "Seite 1 von 3"), ("Drittens Anlage", "Seite 3 von 3"),
                             ("Zweitens Abrechnung", "Seite 2 von 3")], to: source)
        let archive = try Archive(folder: folder.appendingPathComponent("archiv"))
        let index = try SearchIndex(url: archive.folder.appendingPathComponent(SearchIndex.fileName))
        let result = try await ImportProcessor.process(file: source, archive: archive, index: index,
                                                       options: ImportOptions(useSummarizer: false))
        let pdf = try #require(PDFDocument(url: result.url))
        #expect(pdf.pageCount == 3)
        #expect(pdf.page(at: 0)?.string?.contains("Erstens") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)
        #expect(pdf.page(at: 1)?.string?.contains("Zweitens") == true)
        #expect(pdf.page(at: 2)?.string?.contains("Drittens") == true)
        #expect(result.meta.pageOrder == [0, 2, 1])
        #expect(result.issues.contains(.pageOrderCorrected(original: [1, 3, 2])))
        #expect(result.issues.maxSeverity == .warning)
        #expect(PDFMetadata.read(pdf)?.pageOrder == [0, 2, 1])
        #expect(result.meta.storage == .appended)  // Original bleibt, nur der Seitenbaum ist neu
    }

    @Test("Import: gescannte Bildseiten werden samt OCR-Ebene umsortiert")
    func importReordersImagePages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Reihenfolge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = folder.appendingPathComponent("text.pdf")
        Self.makePDF(pages: [("Zweitens Abrechnung", "Seite 2 von 2"), ("Erstens Anschreiben", "Seite 1 von 2")], to: text)
        // als Bild-PDF (wie ein Scan)
        let document = try #require(CGPDFDocument(text as CFURL))
        let source = folder.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let out = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for i in 0..<2 {
            let image = try #require(ImageTools.renderPDFPage(document, index: i, dpi: 200, gray: true))
            out.beginPDFPage(nil)
            out.draw(image, in: box)
            out.endPDFPage()
        }
        out.closePDF()
        let archive = try Archive(folder: folder.appendingPathComponent("archiv"))
        let index = try SearchIndex(url: archive.folder.appendingPathComponent(SearchIndex.fileName))
        for preset in [SizePreset.original, .kb150] {
            let result = try await ImportProcessor.process(file: source, archive: archive, index: index,
                                                           options: ImportOptions(pdfPreset: preset, useSummarizer: false))
            let pdf = try #require(PDFDocument(url: result.url))
            #expect(pdf.page(at: 0)?.string?.contains("Erstens") == true, "\(preset)")
            #expect(pdf.page(at: 1)?.string?.contains("Zweitens") == true, "\(preset)")
            #expect(pdf.page(at: 1)?.string?.contains("Erstens") != true, "\(preset)")
            #expect(result.meta.pages == [.ocr, .ocr])
            #expect(result.meta.pageOrder == [1, 0])
            try index.remove(path: result.url.path)  // sonst gilt die zweite Runde als Duplikat
        }
    }

    @Test("Umsortieren im Anhänger: verschachtelter Seitenbaum, geerbte Größe")
    func appenderReordersNestedTree() throws {
        // Wurzel (A4) → [Unterbaum (quer) → [S1, S2], S3]
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]
        func obj(_ num: Int, _ body: String) {
            offsets[num] = pdf.count
            pdf.append(Data("\(num) 0 obj\n\(body)\nendobj\n".utf8))
        }
        func content(_ text: String) -> String {
            let ops = "BT /F1 18 Tf 60 400 Td (\(text)) Tj ET"
            return "<< /Length \(ops.utf8.count) >>\nstream\n\(ops)\nendstream"
        }
        obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        obj(2, "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 3 /MediaBox [0 0 595 842] /Resources << /Font << /F1 10 0 R >> >> >>")
        obj(3, "<< /Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /MediaBox [0 0 842 595] >>")
        obj(4, "<< /Type /Page /Parent 3 0 R /Contents 7 0 R >>")
        obj(5, "<< /Type /Page /Parent 3 0 R /Contents 8 0 R >>")
        obj(6, "<< /Type /Page /Parent 2 0 R /Contents 9 0 R >>")
        obj(7, content("Alpha Seite"))
        obj(8, content("Bravo Seite"))
        obj(9, content("Charlie Seite"))
        obj(10, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let xref = pdf.count
        var table = "xref\n0 11\n0000000000 65535 f \n"
        for n in 1...10 { table += String(format: "%010d 00000 n \n", offsets[n]!) }
        pdf.append(Data((table + "trailer\n<< /Size 11 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
        #expect(PDFDocument(data: pdf)?.pageCount == 3)

        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let meta = DocumentMetadata(number: 5, documentDate: date, dateSource: .text, titleSource: .none, source: .pdf, storage: .appended)
        let stamped = try PDFAppender.stamp(original: pdf, stampText: PDFBuilder.stampText(number: 5, date: date), overlays: [],
                                            meta: meta, title: "", summary: "", order: [2, 0, 1])
        #expect(stamped.prefix(pdf.count) == pdf)  // Original bitgenau erhalten
        let result = try #require(PDFDocument(data: stamped))
        #expect(result.pageCount == 3)
        #expect(result.page(at: 0)?.string?.contains("Charlie") == true)
        #expect(result.page(at: 0)?.string?.contains("Nr. 000005") == true)
        #expect(result.page(at: 1)?.string?.contains("Alpha") == true)
        #expect(result.page(at: 2)?.string?.contains("Bravo") == true)
        #expect(result.page(at: 1)?.string?.contains("Nr. 000005") != true)
        // Größen bleiben: Charlie hoch (A4), Alpha/Bravo quer
        #expect(result.page(at: 0)?.bounds(for: .mediaBox).width == 595)
        #expect(result.page(at: 1)?.bounds(for: .mediaBox).width == 842)
        #expect(result.page(at: 2)?.bounds(for: .mediaBox).width == 842)
        #expect(PDFMetadata.read(result)?.number == 5)
        #expect(throws: PDFRawError.self) {
            try PDFAppender.stamp(original: pdf, stampText: "x", overlays: [], meta: meta, title: "", summary: "", order: [0, 0, 1])
        }
    }
}
