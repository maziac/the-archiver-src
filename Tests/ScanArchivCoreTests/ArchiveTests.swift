import Foundation
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
}
