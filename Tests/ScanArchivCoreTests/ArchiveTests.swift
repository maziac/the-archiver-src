import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct ArchiveTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScanArchivTests-\(UUID().uuidString)")
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 18, hour: 12).date!

    @Test func fileNameFormat() {
        #expect(Archive.fileName(date: date, number: 123) == "2026-09-18_000123.pdf")
        let parsed = Archive.parse(fileName: "2026-09-18_000123.pdf")
        #expect(parsed?.number == 123)
        #expect(Archive.parse(fileName: "scan.pdf") == nil)
    }

    @Test func numbersAreSequential() throws {
        let archive = try Archive(folder: folder)
        #expect(archive.peekNextNumber() == 1)
        let first = try archive.save(date: date) { _ in Data("a".utf8) }
        let second = try archive.save(date: date) { _ in Data("b".utf8) }
        #expect(first.number == 1)
        #expect(second.number == 2)
        #expect(second.url.lastPathComponent == "2026-09-18_000002.pdf")
    }

    @Test func existingFilesWinOverCounter() throws {
        let archive = try Archive(folder: folder)
        _ = try archive.save(date: date) { _ in Data() }
        // jemand kopiert eine Datei mit höherer Nummer hinein
        try Data().write(to: folder.appendingPathComponent("2025-01-01_000050.pdf"))
        #expect(archive.peekNextNumber() == 51)
        // Zähler gelöscht: vorhandene Dateien verhindern doppelte Nummern
        try FileManager.default.removeItem(at: folder.appendingPathComponent("counter.json"))
        #expect(try archive.save(date: date) { _ in Data() }.number == 51)
    }

    @Test func failedPDFDoesNotConsumeNumber() throws {
        struct Boom: Error {}
        let archive = try Archive(folder: folder)
        #expect(throws: Boom.self) { try archive.save(date: date) { _ in throw Boom() } }
        #expect(archive.peekNextNumber() == 1)
    }

    @Test func titleInFileName() {
        #expect(Archive.fileName(date: date, number: 7, title: "Stromrechnung Stadtwerke München 09/2026")
                == "2026-09-18_000007_Stromrechnung-Stadtwerke-München-09-2026.pdf")
        #expect(Archive.slug("  Kfz: Versicherung / \"Allianz\"  ") == "Kfz-Versicherung-Allianz")
        #expect(Archive.slug(String(repeating: "Wort ", count: 30)).count <= 60)
        #expect(Archive.parse(fileName: "2026-09-18_000007_Stromrechnung-Stadtwerke.pdf")?.number == 7)
    }

    @Test func numbersCountAcrossTitledFiles() throws {
        let archive = try Archive(folder: folder)
        try Data().write(to: folder.appendingPathComponent("2026-01-01_000009_Irgendwas.pdf"))
        let saved = try archive.save(date: date, title: "Mietvertrag") { _ in Data() }
        #expect(saved.number == 10)
        #expect(saved.url.lastPathComponent == "2026-09-18_000010_Mietvertrag.pdf")
    }

    @Test func updateMetadataRenamesAndKeepsText() throws {
        let archive = try Archive(folder: folder)
        let image = PDFBuilderTests.renderPage("Stromrechnung Oktober")
        let page = PDFPageInput(image: image, lines: try OCRService.recognize(image))
        let saved = try archive.save(date: date) { number in
            try PDFBuilder.build(pages: [page], number: number, date: date, dpi: 150)
        }
        let sizeBefore = try Data(contentsOf: saved.url).count
        let newDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 8, day: 1, hour: 12).date!

        let newURL = try archive.updateMetadata(url: saved.url, date: newDate, title: "Stromrechnung SWM", summary: "Rechnung über Strom.")
        #expect(newURL.lastPathComponent == "2026-08-01_000001_Stromrechnung-SWM.pdf")
        #expect(!FileManager.default.fileExists(atPath: saved.url.path))

        let pdf = try #require(PDFDocument(url: newURL))
        let attrs = pdf.documentAttributes ?? [:]
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "Stromrechnung SWM")
        #expect(attrs[PDFDocumentAttribute.subjectAttribute] as? String == "Rechnung über Strom.")
        #expect((attrs[PDFDocumentAttribute.keywordsAttribute] as? [String])?.contains("000001") == true)
        #expect(pdf.string?.contains("Stromrechnung") == true)
        #expect(pdf.string?.contains("Nr. 000001") == true)
        let sizeAfter = try Data(contentsOf: newURL).count
        #expect(sizeAfter < sizeBefore * 2, "vorher \(sizeBefore), nachher \(sizeAfter)")
    }
}
