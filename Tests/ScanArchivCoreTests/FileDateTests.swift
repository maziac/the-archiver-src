import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct FileDateTests {
    let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 19, hour: 12).date!
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileDate-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func ymd(_ date: Date?) -> String? { date.map(Archive.formatDate) }

    @Test(arguments: [
        ("2025-12-11_Bestellbestaetigung.pdf", "2025-12-11"),
        ("20251211_Rechnung.pdf", "2025-12-11"),
        ("Rechnung vom 11.12.2025.pdf", "2025-12-11"),
        ("Scan_2024_03_15.jpg", nil as String?),       // kein unterstütztes Format
        ("Kontoauszug 123456789.pdf", nil),            // lange Zahl ist kein Datum
        ("20991231_Zukunft.pdf", nil),                 // unplausibel
    ])
    func fileNames(name: String, expected: String?) {
        #expect(ymd(FileDate.fromFileName(name, now: now)) == expected, "\(name)")
    }

    @Test func orderFileNameThenPDFThenFileSystem() throws {
        // PDF mit Erstelldatum 2023-05-06 und Dateidatum 2022-01-02
        let pdfCreation = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2023, month: 5, day: 6, hour: 12).date!
        let fsDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2022, month: 1, day: 2, hour: 12).date!
        func makePDF(_ name: String, creation: Date?) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 100, height: 100)
            let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
            var output = data as Data
            if let creation {
                // Erstelldatum direkt ins Info-Dictionary (PDFKit würde es beim Speichern überschreiben)
                let update = PDFIncrementalUpdate(try PDFRawDocument(data: output))
                update.trailerChanges["Info"] = update.add(.dict(PDFDict([("CreationDate", .text(PDFAppender.pdfDate(creation)))])))
                output = update.write()
            }
            try output.write(to: url)
            try FileManager.default.setAttributes([.creationDate: fsDate, .modificationDate: fsDate], ofItemAtPath: url.path)
            return url
        }
        let named = try makePDF("2024-07-08 Brief.pdf", creation: pdfCreation)
        #expect(FileDate.best(for: named, now: now)?.source == .fileName)
        #expect(ymd(FileDate.best(for: named, now: now)?.date) == "2024-07-08")

        let withCreation = try makePDF("Brief.pdf", creation: pdfCreation)
        #expect(FileDate.best(for: withCreation, now: now)?.source == .pdfCreation)
        #expect(ymd(FileDate.best(for: withCreation, now: now)?.date) == "2023-05-06")

        let image = folder.appendingPathComponent("Foto.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("x"), to: image)
        try FileManager.default.setAttributes([.creationDate: fsDate, .modificationDate: fsDate], ofItemAtPath: image.path)
        #expect(FileDate.best(for: image, now: now)?.source == .fileDate)
        #expect(ymd(FileDate.best(for: image, now: now)?.date) == "2022-01-02")
    }

    /// Kopieren in den Eingang ändert das Dateidatum nicht.
    @Test func copyKeepsFileDate() throws {
        let old = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2021, month: 3, day: 4, hour: 12).date!
        let source = folder.appendingPathComponent("Foto.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("x"), to: source)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: source.path)
        let copy = folder.appendingPathComponent("Kopie.png")
        try FileManager.default.copyItem(at: source, to: copy)
        #expect(ymd(FileDate.best(for: copy)?.date) == "2021-03-04")
    }

    /// Import ohne Datum im Text: Datum aus dem Dateinamen, kein Vermerk „kein Datum“.
    @Test func importUsesFileNameDate() async throws {
        let png = folder.appendingPathComponent("2025-12-11_Notiz.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("Notiz ohne Datum im Text"), to: png)
        let archive = try Archive(folder: folder.appendingPathComponent("archiv"))
        let index = try SearchIndex(url: archive.folder.appendingPathComponent(SearchIndex.fileName))
        let result = try await ImportProcessor.process(file: png, archive: archive, index: index,
                                                       options: ImportOptions(useSummarizer: false))
        #expect(Archive.formatDate(result.date) == "2025-12-11")
        #expect(result.meta.dateSource == .fileName)
        #expect(!result.issues.contains(.noDate))
        #expect(result.url.lastPathComponent.hasPrefix("2025-12-11_"))
    }
}
