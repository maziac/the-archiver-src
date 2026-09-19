import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

@Suite("Seiten bearbeiten")
struct RearrangeTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rearrange-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 19, hour: 12).date!

    enum Kind: String, CaseIterable { case appended, scan, rewritten }

    /// Archivdatei mit drei Seiten „Alpha/Bravo/Charlie“, erzeugt auf dem gewünschten Weg.
    func makeArchived(_ kind: Kind) async throws -> (Archive, URL) {
        let archive = try Archive(folder: folder.appendingPathComponent("archiv-\(kind.rawValue)"))
        let words = ["Alphabetisch", "Bravourstueck", "Charlottenburg"]
        let meta = { (number: Int, storage: DocumentMetadata.Storage) in
            DocumentMetadata(number: number, documentDate: self.date, dateSource: .text, titleSource: .none,
                             source: kind == .scan ? .scan : .pdf, pages: [.embedded, .embedded, .embedded], storage: storage)
        }
        switch kind {
        case .scan:
            var inputs: [PDFPageInput] = []
            for word in words {
                let image = PDFBuilderTests.renderPage(word)
                let lines = try await OCRService.recognize(image)
                let encoded = PageCompressor.encode(image, pageSize: CGSize(width: 595, height: 842), preset: .original, color: .original)
                inputs.append(PDFPageInput(encoded: encoded, lines: lines))
            }
            let saved = try archive.save(date: date) { number in
                let data = try PDFBuilder.build(pages: inputs, number: number, date: date, dpi: 150, title: "", summary: "")
                return try PDFMetadata.finalize(data, meta: meta(number, .created), title: "", summary: "")
            }
            return (archive, saved.url)
        case .appended, .rewritten:
            let source = folder.appendingPathComponent("quelle-\(kind.rawValue).pdf")
            PageNumberingTests.makePDF(pages: words.map { ($0, "Fußzeile") }, to: source)
            let saved = try archive.save(date: date) { number in
                if kind == .appended {
                    return try PDFAppender.stamp(original: Data(contentsOf: source), stampText: PDFBuilder.stampText(number: number, date: date),
                                                 overlays: [], meta: meta(number, .appended), title: "", summary: "")
                }
                return try PDFStamper.stamp(source: source, pages: (0..<3).map { PDFStamper.PageEdit(index: $0) }, number: number,
                                            date: date, title: "", summary: "", meta: meta(number, .rewritten))
            }
            return (archive, saved.url)
        }
    }

    /// Anteil roter Pixel im Stempelbereich einer Seite (so wie sie angezeigt wird).
    func redShare(_ url: URL, page index: Int, stampText: String) throws -> Double {
        let document = try #require(CGPDFDocument(url as CFURL))
        let dpi = 144.0
        let image = try #require(ImageTools.renderPDFPage(document, index: index, dpi: dpi, gray: false))
        let size = CGSize(width: Double(image.width) / dpi * 72, height: Double(image.height) / dpi * 72)
        let box = PDFBuilder.stampGeometry(stampText, pageSize: size).box
        let data = image.dataProvider!.data! as Data
        let scale = dpi / 72
        var red = 0, total = 0
        for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
            for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
                let row = image.height - 1 - y
                let i = row * image.bytesPerRow + x * 4
                total += 1
                if data[i] > 150, data[i + 1] < 90, data[i + 2] < 90 { red += 1 }
            }
        }
        return Double(red) / Double(max(total, 1))
    }

    @Test("Stempel wandert auf die neue erste Seite", arguments: Kind.allCases)
    func movesStamp(kind: Kind) async throws {
        let (archive, url) = try await makeArchived(kind)
        let before = try Data(contentsOf: url)
        let stamp = PDFBuilder.stampText(number: 1, date: date)
        #expect(try redShare(url, page: 0, stampText: stamp) > 0.02)

        let result = try archive.rearrange(url: url, order: [2, 0, 1], rotations: [0, 0, 90], title: "", summary: "")
        let after = try Data(contentsOf: url)
        #expect(after.prefix(before.count) == before, "bisheriger Inhalt bleibt erhalten")
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.page(at: 0)?.string?.contains("Charlottenburg") == true)
        #expect(pdf.page(at: 1)?.string?.contains("Alphabetisch") == true)
        #expect(pdf.page(at: 2)?.string?.contains("Bravourstueck") == true)
        #expect(pdf.page(at: 0)?.string?.contains(stamp) == true)
        #expect(pdf.page(at: 2)?.rotation == 90)
        #expect(PDFMetadata.read(pdf)?.number == 1)
        #expect(result.meta.pageOrder == [2, 0, 1])
        #expect(result.pageTexts[0].contains("Charlottenburg"))
        // sichtbar: neuer Stempel vorn, alter überdeckt
        #expect(try redShare(url, page: 0, stampText: stamp) > 0.02)
        #expect(try redShare(url, page: 1, stampText: stamp) == 0)
    }

    @Test("Nur drehen der ersten Seite: Stempel bleibt oben rechts")
    func rotateFirstPage() async throws {
        let (archive, url) = try await makeArchived(.appended)
        let stamp = PDFBuilder.stampText(number: 1, date: date)
        _ = try archive.rearrange(url: url, order: [0, 1, 2], rotations: [180, 0, 0], title: "", summary: "")
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.page(at: 0)?.rotation == 180)
        #expect(try redShare(url, page: 0, stampText: stamp) > 0.02)
        #expect(PDFMetadata.read(pdf)?.number == 1)
    }

    @Test("Import korrigiert, Benutzer stellt das Original wieder her")
    func restoreOriginalOrder() async throws {
        let source = folder.appendingPathComponent("vertauscht.pdf")
        PageNumberingTests.makePDF(pages: [("Erstens Anschreiben", "Seite 1 von 3"), ("Drittens Anlage", "Seite 3 von 3"),
                                           ("Zweitens Abrechnung", "Seite 2 von 3")], to: source)
        let archive = try Archive(folder: folder.appendingPathComponent("archiv"))
        let index = try SearchIndex(url: archive.folder.appendingPathComponent(SearchIndex.fileName))
        let imported = try await ImportProcessor.process(file: source, archive: archive, index: index,
                                                         options: ImportOptions(useSummarizer: false))
        #expect(imported.meta.pageOrder == [0, 2, 1])

        // aktuell 1-2-3 → Originallage 1-3-2
        let result = try archive.rearrange(url: imported.url, order: [0, 2, 1], rotations: [0, 0, 0], title: "", summary: "")
        #expect(result.meta.pageOrder == nil)
        #expect(!result.meta.issues.contains { if case .pageOrderCorrected = $0 { true } else { false } })
        try index.update(oldPath: imported.url.path, newURL: imported.url, date: imported.date, title: "", summary: "",
                         meta: result.meta, text: result.pageTexts.joined(separator: "\n\n"))
        let record = try #require(try index.search("Drittens").first)
        #expect(record.issues == [.noSuggestion(DocumentIssue.suggestionDisabled)])  // nur der Reihenfolge-Vermerk ist weg
        let pdf = try #require(PDFDocument(url: imported.url))
        #expect(pdf.page(at: 1)?.string?.contains("Drittens") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)
    }

    @Test func invalidOrderIsRejected() async throws {
        let (archive, url) = try await makeArchived(.appended)
        let before = try Data(contentsOf: url)
        #expect(throws: ArchiveError.self) {
            try archive.rearrange(url: url, order: [0, 0, 1], rotations: [0, 0, 0], title: "", summary: "")
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
