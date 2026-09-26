import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct CategoryTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScanArchivCategories-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Normalisieren

    @Test func normalizeMatchesKnownSpelling() {
        let known = ["Rechnung", "Krankenkasse", "Absender/DAK"]
        #expect(Categories.normalize(["rechnungen", " KRANKENKASSE "], sender: nil, known: known) == ["Krankenkasse", "Rechnung"])
        #expect(Categories.normalize(["Steuern"], sender: nil, known: ["Steuer"]) == ["Steuer"])
        #expect(Categories.normalize(["Bescheid"], sender: nil, known: known) == ["Bescheid"])  // neu
    }

    @Test func normalizeSender() {
        let known = ["Absender/DAK", "Absender/Deutsche Rentenversicherung"]
        #expect(Categories.normalize([], sender: "DAK-Gesundheit", known: known) == ["Absender/DAK"])
        #expect(Categories.normalize([], sender: "deutsche rentenversicherung", known: known)
                == ["Absender/Deutsche Rentenversicherung"])
        #expect(Categories.normalize(["Rechnung"], sender: "Techniker Krankenkasse", known: known)
                == ["Absender/Techniker Krankenkasse", "Rechnung"])
        #expect(Categories.normalize([], sender: "  ", known: known) == [])
    }

    @Test func normalizeCleansAndDeduplicates() {
        #expect(Categories.normalize(["Rechnung", "rechnung", "", "  /  "], sender: nil, known: []) == ["Rechnung"])
        #expect(Categories.normalize(["„Vertrag“"], sender: "A/B GmbH", known: []) == ["Absender/A B GmbH", "Vertrag"])
        // Absender nur über `sender`, nicht aus der Kategorienliste
        #expect(Categories.normalize(["Absender/X", "Rente"], sender: nil, known: []) == ["Rente"])
    }

    @Test func normalizeCompoundsSenderWordsAndNewLimit() {
        let known = Categories.defaults
        #expect(Categories.normalize(["Stromrechnung", "Beitragsbescheide", "Altersrente"], sender: nil, known: known)
                == ["Bescheid", "Rechnung", "Rente"])
        #expect(Categories.normalize(["Rechnung", "Stadtwerke"], sender: "Stadtwerke München", known: known)
                == ["Absender/Stadtwerke München", "Rechnung"])
        #expect(Categories.normalize(["Strom", "Betrag", "Bezahlung"], sender: nil, known: known) == ["Strom"])
    }

    @Test func verifiedNeedsEvidenceForTopics() {
        let rundfunk = "Beitragsservice Festsetzungsbescheid Rundfunkbeiträge für die Wohnung Parkstr. 7"
        #expect(Categories.verified(["Bescheid", "Wohnen"], text: rundfunk) == ["Bescheid"])
        let nebenkosten = "Hausverwaltung Schmidt, Betriebskostenabrechnung für Ihre Wohnung"
        #expect(Categories.verified(["Rechnung", "Wohnen"], text: nebenkosten) == ["Rechnung", "Wohnen"])
        #expect(Categories.verified(["Absender/DAK", "Strom"], text: "") == ["Absender/DAK", "Strom"])
        #expect(Categories.normalize(["Stadtwerke München"], sender: "Stadtwerke München GmbH", known: []) == ["Absender/Stadtwerke München GmbH"])
    }

    @Test func expandedAndHelpers() {
        #expect(Categories.expanded(["Absender/DAK", "Rechnung", "Absender/TK"]) == ["Absender", "Absender/DAK", "Rechnung", "Absender/TK"])
        #expect(Categories.indexField(["Absender/DAK"]) == "\nAbsender\nAbsender/DAK\n")
        #expect(Categories.indexField([]) == "")
        #expect(Categories.indexField(nil) == nil)
        #expect(Categories.cleanPath(" Absender /  DAK ") == "Absender/DAK")
        #expect(Categories.parent("Absender/DAK") == "Absender")
        #expect(Categories.parent("Rechnung") == nil)
        #expect(Categories.leaf("Absender/DAK") == "DAK")
        #expect(Categories.display("Absender/DAK") == "Absender › DAK")
    }

    @Test func renamed() {
        #expect(Categories.renamed(["Absender/DAK", "Rechnung"], from: "Absender/DAK", to: "Absender/DAK-Gesundheit")
                == ["Absender/DAK-Gesundheit", "Rechnung"])
        #expect(Categories.renamed(["Absender/DAK", "Rechnung"], from: "Absender", to: "Von") == ["Rechnung", "Von/DAK"])
        #expect(Categories.renamed(["Rechnungen", "Rechnung"], from: "Rechnungen", to: "Rechnung") == ["Rechnung"])
        #expect(Categories.renamed(["Rechnung"], from: "Rente", to: "X") == nil)
        #expect(Categories.renamed(["Rechnung", "Rente"], from: "Rente", to: nil) == ["Rechnung"])
    }

    @Test func promptListsKindsAndSenders() {
        let prompt = Summarizer.prompt(modelText: "Text", known: ["Rechnung", "Versicherung/KFZ", "Absender/DAK"])
        #expect(prompt.contains("\n- Rechnung: Zahlungsaufforderung"))
        #expect(prompt.contains("\n- Versicherung/KFZ\n"))  // eigene Kategorie ohne Beschreibung
        #expect(prompt.hasPrefix("Dokumenttext:\nText\n"))
        #expect(prompt.hasSuffix("Bekannte Absender: DAK\n"))
    }

    // MARK: Metadaten

    static func sampleMeta(_ categories: [String]?) -> DocumentMetadata {
        var meta = DocumentMetadata(number: 5, documentDate: Date(timeIntervalSinceReferenceDate: 800_000_000), dateSource: .ai,
                                    titleSource: .ai, archivedAt: Date(timeIntervalSinceReferenceDate: 800_000_100), source: .pdf)
        meta.categories = categories
        return meta
    }

    @Test func metadataRoundtripWithCategories() throws {
        let meta = Self.sampleMeta(["Absender/Techniker Krankenkasse", "Kündigung"])
        let json = try meta.encoded()
        let ascii = json.allSatisfy { $0.isASCII }
        #expect(ascii)
        let decoded = DocumentMetadata.decode(json)
        #expect(decoded == meta)
    }

    @Test func oldMetadataHasNoCategories() throws {
        let json = try Self.sampleMeta(nil).encoded()
        #expect(!json.contains("categories"))
        let decoded = DocumentMetadata.decode(json)
        #expect(decoded != nil)
        #expect(decoded?.categories == nil)
    }

    @Test func updateMetadataStoresCategoriesAppended() throws {
        let archive = try Archive(folder: folder)
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let page = PDFPageInput(image: PDFBuilderTests.renderPage("Rechnung DAK"), lines: [])
        let saved = try archive.save(date: date) { number in
            var meta = Self.sampleMeta(nil)
            meta.number = number
            return try PDFMetadata.finalize(try PDFBuilder.build(pages: [page], number: number, date: date, dpi: 150),
                                            meta: meta, title: "", summary: "")
        }
        let before = try Data(contentsOf: saved.url)
        let result = try archive.updateMetadata(url: saved.url, date: date, title: "", summary: "") {
            $0.categories = ["Absender/DAK", "Rechnung"]
        }
        let after = try Data(contentsOf: result.url)
        #expect(after.prefix(before.count) == before)  // Original bleibt Präfix
        #expect(PDFMetadata.read(url: result.url)?.categories == ["Absender/DAK", "Rechnung"])
        let keywords = PDFDocument(url: result.url)?.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String]
        #expect(keywords?.contains("Rechnung") == true)
    }

    // MARK: Index

    func makeIndex() throws -> SearchIndex {
        let index = try SearchIndex(url: folder.appendingPathComponent(SearchIndex.fileName))
        let docs: [(Int, [String]?, String)] = [
            (1, ["Absender/DAK", "Rechnung"], "Beitrag"),
            (2, ["Absender/DAK", "Bescheid"], "Beitrag"),
            (3, ["Absender/Techniker Krankenkasse", "Rechnung"], "Beitrag"),
            (4, [], "Beitrag"),
            (5, nil, "Beitrag"),
        ]
        for (number, categories, text) in docs {
            try index.add(number: number, date: Date(), url: folder.appendingPathComponent("\(number).pdf"), pages: 1,
                          text: text, meta: Self.sampleMeta(categories))
        }
        return index
    }

    @Test func filterIsAndCombined() throws {
        let index = try makeIndex()
        #expect(try index.search("", categories: ["Absender/DAK", "Rechnung"]).map(\.number) == [1])
        #expect(try index.search("", categories: ["Rechnung"]).map(\.number) == [3, 1])
        #expect(try index.search("", categories: ["Absender"]).map(\.number) == [3, 2, 1])
        #expect(try index.search("beitrag", categories: ["Absender/DAK"]).map(\.number) == [2, 1])
        #expect(try index.search("", tagQueries: ["Beitrag"], categories: ["Bescheid"]).map(\.number) == [2])
        // „Absender/D“ ist keine Kategorie – kein Treffer über Teilpfade
        #expect(try index.search("", categories: ["Absender/D"]).isEmpty)
    }

    @Test func searchFieldFindsCategoryName() throws {
        #expect(try makeIndex().search("bescheid").map(\.number) == [2])
    }

    @Test func countsAndVocabulary() throws {
        let index = try makeIndex()
        let all = try index.categoryCounts()
        #expect(all["Absender"] == 3)
        #expect(all["Absender/DAK"] == 2)
        #expect(all["Rechnung"] == 2)
        let dak = try index.categoryCounts(categories: ["Absender/DAK"])
        #expect(dak["Rechnung"] == 1)
        #expect(dak["Absender/Techniker Krankenkasse"] == nil)
        #expect(try index.allCategories() == ["Absender/DAK", "Absender/Techniker Krankenkasse", "Bescheid", "Rechnung"])
        #expect(try index.countWithoutCategories() == 1)
        #expect(try index.recordsWithoutCategories().map(\.path) == [folder.appendingPathComponent("5.pdf").path])
    }

    @Test func updateChangesCategories() throws {
        let index = try makeIndex()
        let url = folder.appendingPathComponent("5.pdf")
        try index.update(oldPath: url.path, newURL: url, date: Date(), title: "", summary: "",
                         meta: Self.sampleMeta(["Rente"]))
        #expect(try index.search("", categories: ["Rente"]).map(\.number) == [5])
        #expect(try index.countWithoutCategories() == 0)
        #expect(try index.record(path: url.path)?.categories == ["Rente"])
    }
}
