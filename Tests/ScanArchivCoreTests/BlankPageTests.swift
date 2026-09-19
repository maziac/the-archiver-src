import CoreGraphics
import Foundation
import PDFKit
@testable import ScanArchivCore
import Testing

@Suite("Leere Seiten")
struct BlankPageTests {
    /// A4 bei 300 dpi, weiß; `draw` zeichnet darauf.
    static func page(_ draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let ctx = CGContext(data: nil, width: 2480, height: 3508, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2480, height: 3508))
        draw(ctx)
        return ctx.makeImage()!
    }

    @Test func whitePageIsBlank() {
        #expect(BlankPage.isBlank(Self.page()))
    }

    @Test("Staub und Scannerschatten am Rand")
    func dustAndEdges() {
        let image = Self.page { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<30 { ctx.fill(CGRect(x: 300 + i * 60, y: 500 + (i * 97) % 2500, width: 4, height: 4)) }
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 3508))  // dunkler Rand links
        }
        #expect(BlankPage.isBlank(image))
    }

    @Test("Lochung und Maschinencode am Rand (Rückseite eines Bescheids)")
    func punchHolesAndMachineCode() {
        let image = Self.page { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            // DataMatrix-Code ca. 12 × 13 mm, 5 mm vom rechten Rand
            for row in 0..<24 { for col in 0..<22 where (row * 7 + col * 3) % 5 < 2 {
                ctx.fill(CGRect(x: 2280 + col * 6, y: 1900 + row * 6, width: 6, height: 6))
            } }
            // Lochung: zwei dunkle Kreise 12 mm vom rechten Rand
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            ctx.setLineWidth(5)
            for y in [1300, 2130] { ctx.strokeEllipse(in: CGRect(x: 2270, y: y, width: 70, height: 70)) }
        }
        #expect(BlankPage.isBlank(image), "Anteil \(BlankPage.inkShare(image))")
    }

    @Test("Durchscheinender Text der Rückseite")
    func showThrough() {
        let image = Self.page { ctx in
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
            for line in 0..<40 { ctx.fill(CGRect(x: 250, y: 400 + line * 70, width: 1900, height: 22)) }
        }
        #expect(BlankPage.isBlank(image))
    }

    @Test("Dünne Unterschrift ist Inhalt")
    func signature() {
        let image = Self.page { ctx in
            ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: 1500, y: 700))
            for i in 1...40 {
                ctx.addLine(to: CGPoint(x: 1500 + i * 12, y: 700 + (i % 2 == 0 ? 60 : -20)))
            }
            ctx.strokePath()
        }
        #expect(!BlankPage.isBlank(image), "Anteil \(BlankPage.inkShare(image))")
    }

    @Test func textPageIsNotBlank() {
        #expect(!BlankPage.isBlank(PDFBuilderTests.renderPage("Rechnung Nummer 4711")))
    }

    /// Bild-PDF aus den gegebenen Seitenbildern.
    static func imagePDF(_ images: [CGImage], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        for image in images {
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    static func scribble() -> CGImage {
        page { ctx in
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(8)
            ctx.addEllipse(in: CGRect(x: 600, y: 1200, width: 1200, height: 900))
            ctx.strokePath()
        }
    }

    @Test("Import: leere Seite ist kein Problem, Kritzelei ohne Text schon")
    func importMarksBlankPages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Leer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("scan.pdf")
        Self.imagePDF([PDFBuilderTests.renderPage("Mietvertrag Wohnung"), Self.page(), Self.scribble()], to: source)
        let archive = try Archive(folder: folder.appendingPathComponent("archiv"))
        let index = try SearchIndex(url: archive.folder.appendingPathComponent(SearchIndex.fileName))
        let result = try await ImportProcessor.process(file: source, archive: archive, index: index,
                                                       options: ImportOptions(useSummarizer: false))
        #expect(result.meta.pages == [.ocr, .blank, .none])
        #expect(result.issues.contains(.noText(pages: [3])))
        #expect(!result.issues.contains { if case let .noText(pages) = $0 { pages.contains(2) } else { false } })
        #expect(DocumentInfo.textText(result.meta, pageCount: 3).contains("1 Seite leer"))
    }

    @Test("Nachprüfung älterer Dokumente")
    func recheckOldDocuments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Leer-\(UUID().uuidString)")
        let archive = try Archive(folder: folder)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let pages = [PDFBuilderTests.renderPage("Kontoauszug Juli"), Self.page(), Self.scribble()].map {
            PDFPageInput(encoded: PageCompressor.encode($0, pageSize: CGSize(width: 595, height: 842), preset: .original, color: .original),
                         lines: [])
        }
        let saved = try archive.save(date: date, title: "Kontoauszug") { number in
            let meta = DocumentMetadata(number: number, documentDate: date, dateSource: .text, titleSource: .manual, source: .scan,
                                        pages: [.ocr, .none, .none], issues: [.noText(pages: [2, 3])], storage: .created)
            let data = try PDFBuilder.build(pages: pages, number: number, date: date, dpi: 300, title: "Kontoauszug", summary: "")
            return try PDFMetadata.finalize(data, meta: meta, title: "Kontoauszug", summary: "")
        }
        let result = try #require(try archive.recheckBlankPages(url: saved.url, date: date, title: "Kontoauszug", summary: ""))
        #expect(result.url == saved.url)
        #expect(result.meta?.issues == [.noText(pages: [3])])
        #expect(result.meta?.pages == [.ocr, .blank, .none])
        // zweiter Lauf: nichts mehr zu tun
        #expect(try archive.recheckBlankPages(url: saved.url, date: date, title: "Kontoauszug", summary: "") == nil)
    }
}
