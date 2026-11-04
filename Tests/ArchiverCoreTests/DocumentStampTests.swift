import Foundation
import PDFKit
import Testing
@testable import ArchiverCore

/// Nummernstempel zur Laufzeit: Anzeige/Druck, Kopie mit und ohne Nummer.
@Suite("Nummernstempel")
struct DocumentStampTests {
    let helper = RearrangeTests()

    @Test("Kopie mit Nummer: Stempel angehängt, Archivdatei ist Präfix", arguments: RearrangeTests.Kind.allCases)
    func copyWithNumber(kind: RearrangeTests.Kind) async throws {
        let (_, url) = try await helper.makeArchived(kind)
        let original = try Data(contentsOf: url)
        let stamp = PDFBuilder.stampText(number: 1, date: helper.date)
        let copy = try DocumentStamp.copyData(url: url, withNumber: true)
        #expect(copy.prefix(original.count) == original)
        #expect(try Data(contentsOf: url) == original, "Archivdatei bleibt unverändert")
        let pdf = try #require(PDFDocument(data: copy))
        #expect(pdf.pageCount == 3)
        #expect(pdf.page(at: 0)?.string?.contains(stamp) == true)
        #expect(pdf.page(at: 1)?.string?.contains(stamp) != true)
        #expect(PDFMetadata.read(pdf)?.number == 1)
        let page = try #require(pdf.page(at: 0))
        #expect(try withExtendedLifetime(pdf) { try RearrangeTests.redShare(page, stampText: stamp) } > 0.02)
    }

    @Test("Kopie ohne Nummer = Archivdatei", arguments: RearrangeTests.Kind.allCases)
    func copyWithoutNumber(kind: RearrangeTests.Kind) async throws {
        let (_, url) = try await helper.makeArchived(kind)
        let copy = try DocumentStamp.copyData(url: url, withNumber: false)
        #expect(copy == (try Data(contentsOf: url)))
        let pdf = try #require(PDFDocument(data: copy))
        let page = try #require(pdf.page(at: 0))
        #expect(try withExtendedLifetime(pdf) {
            try RearrangeTests.redShare(page, stampText: PDFBuilder.stampText(number: 1, date: helper.date))
        } == 0)
    }

    @Test("Geändertes Datum erscheint im Stempel, Aufnahmedatum bleibt")
    func dateChangeUpdatesStamp() async throws {
        let (archive, url) = try await helper.makeArchived(.appended)
        let archivedAt = try #require(PDFMetadata.read(url: url)).archivedAt
        let newDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2025, month: 3, day: 7, hour: 12).date!
        let updated = try archive.updateMetadata(url: url, date: newDate, title: "Neu", summary: "") { $0.dateSource = .manual }
        let meta = try #require(PDFMetadata.read(url: updated.url))
        #expect(meta.documentDate == newDate)
        #expect(meta.dateSource == .manual)
        #expect(meta.archivedAt == archivedAt)
        #expect(DocumentStamp.text(for: meta) == "Nr. 000001 · 07.03.2025")

        let shown = try #require(DocumentStamp.document(url: updated.url))
        #expect((shown.page(at: 0) as? StampPage)?.stampText == "Nr. 000001 · 07.03.2025")
        #expect((shown.page(at: 1) as? StampPage)?.stampText == nil)
        let copy = try #require(PDFDocument(data: try DocumentStamp.copyData(url: updated.url, withNumber: true)))
        #expect(copy.page(at: 0)?.string?.contains("Nr. 000001 · 07.03.2025") == true)
    }

    @Test("Fremdes PDF ohne Metadaten: kein Stempel")
    func foreignPDFHasNoStamp() throws {
        let url = PDFStamperTests().makeTextPDF()
        #expect(try DocumentStamp.copyData(url: url, withNumber: true) == (try Data(contentsOf: url)))
        let shown = try #require(DocumentStamp.document(url: url))
        #expect(!(shown.page(at: 0) is StampPage))
    }
}
