import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct ImagesToPDFTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Combine-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func makeImages() throws -> [URL] {
        let png = folder.appendingPathComponent("Seite 1.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("Mietvertrag Seite eins"), to: png)
        let jpeg = folder.appendingPathComponent("Seite 2.jpg")
        let jpegData = try #require(PageCompressor.jpegData(PDFBuilderTests.renderPage("Unterschriften Seite zwei"), quality: 0.8))
        try jpegData.write(to: jpeg)
        return [png, jpeg]
    }

    @Test func combinesPagesInOrder() async throws {
        let images = try makeImages()
        let data = try ImagesToPDF.combine(images)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        // A4-ähnliche Seitengröße aus der Bildauflösung (150 dpi)
        #expect(abs((pdf.page(at: 0)?.bounds(for: .mediaBox).width ?? 0) - 595.2) < 1)
        // noch kein Stempel – den vergibt erst der Import
        #expect(pdf.string?.contains("Nr. 0000") != true)
        // JPEG-Seite wird unverändert eingebettet
        let jpegSize = try Data(contentsOf: images[1]).count
        #expect(data.count > jpegSize)
        let cg = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let rendered = try #require(ImageTools.renderPDFPage(cg, index: 1, dpi: 150, gray: true))
        let text = try await OCRService.recognize(rendered)
        #expect(text.map(\.text).joined().contains("Unterschriften"))
    }

    @Test func fileNameMentionsCount() throws {
        let images = try makeImages()
        #expect(ImagesToPDF.fileName(for: images) == "Seite 1 + 1 Bilder.pdf")
        #expect(ImagesToPDF.fileName(for: [images[0]]) == "Seite 1.pdf")
    }

    /// Verbundenes PDF durchläuft den normalen Import: OCR beider Seiten, Stempel, Metadaten.
    @Test func combinedPDFImportsAsOneDocument() async throws {
        let images = try makeImages()
        let combined = folder.appendingPathComponent(ImagesToPDF.fileName(for: images))
        try ImagesToPDF.combine(images).write(to: combined)
        let archiveFolder = folder.appendingPathComponent("archiv")
        let archive = try Archive(folder: archiveFolder)
        let index = try SearchIndex(url: archiveFolder.appendingPathComponent(SearchIndex.fileName))
        let result = try await ImportProcessor.process(file: combined, archive: archive, index: index,
                                                       options: ImportOptions(useSummarizer: false))
        let pdf = try #require(PDFDocument(url: result.url))
        #expect(pdf.pageCount == 2)
        #expect(result.meta.pages == [.ocr, .ocr])
        #expect(pdf.page(at: 0)?.string?.contains("Mietvertrag") == true)
        #expect(pdf.page(at: 1)?.string?.contains("Unterschriften") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)
    }
}
