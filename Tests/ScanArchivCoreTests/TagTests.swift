import Foundation
import Testing
@testable import ScanArchivCore

struct TagQueryTests {
    func fts(_ text: String) throws -> String {
        try TagQuery.fts(try TagQuery.parse(text)) { _ in ["x"] }
    }

    @Test func translatesExample() throws {
        #expect(try fts("(\"Rente\" AND \"DRV\") OR \"Rentenversicherung\"")
                == "((\"Rente\" AND \"DRV\") OR \"Rentenversicherung\")")
    }

    @Test func implicitAndNotAndGermanOperators() throws {
        #expect(try fts("Rente DRV") == "(\"Rente\" AND \"DRV\")")
        #expect(try fts("Rente NOT Witwe") == "(\"Rente\" NOT \"Witwe\")")
        #expect(try fts("Rente AND NOT Witwe") == "(\"Rente\" NOT \"Witwe\")")
        #expect(try fts("Rente UND (Bescheid ODER Mitteilung) NICHT Witwe")
                == "((\"Rente\" AND (\"Bescheid\" OR \"Mitteilung\")) NOT \"Witwe\")")
        #expect(try fts("„Deutsche Rentenversicherung“") == "\"Deutsche Rentenversicherung\"")
    }

    @Test func wildcards() throws {
        #expect(try fts("rente*") == "\"rente\"*")
        var seen: [String] = []
        let suffix = try TagQuery.fts(try TagQuery.parse("*rente")) { pattern in
            seen.append(pattern)
            return ["altersrente", "witwenrente"]
        }
        #expect(suffix == "(\"altersrente\" OR \"witwenrente\")")
        _ = try TagQuery.fts(try TagQuery.parse("*RÉNTE*")) { pattern in
            seen.append(pattern)
            return []
        }
        #expect(seen == ["%rente", "%rente%"])  // klein und ohne Akzente wie der Index
        #expect(try TagQuery.fts(try TagQuery.parse("*xyz")) { _ in [] } == TagQuery.noMatch)
    }

    @Test(arguments: [
        ("(Rente AND DRV", "Klammer nicht geschlossen"),
        ("Rente AND", "Nach AND fehlt ein Begriff"),
        ("NOT Rente", "NOT braucht davor einen Begriff"),
        ("Rente OR", "Nach OR fehlt ein Begriff"),
        ("Rente)", "Klammer „)“ ohne passende „(“"),
        ("\"Rente", "Anführungszeichen nicht geschlossen"),
        ("Re*nte", "„*“ ist nur am Anfang oder Ende"),
        ("", "Der Ausdruck ist leer"),
    ])
    func errors(input: String, message: String) {
        #expect(throws: TagQuery.ParseError.self) { try TagQuery.validate(input) }
        do { try TagQuery.validate(input) } catch {
            #expect(error.localizedDescription.hasPrefix(message), "\(error.localizedDescription)")
        }
    }

    @Test func quotesAreEscaped() throws {
        // FTS-Sonderzeichen bleiben wirkungslos
        #expect(try fts("title:Rente") == "\"title:Rente\"")
        #expect(try fts("NEAR(a b)") == "(\"NEAR\" AND (\"a\" AND \"b\"))")
    }
}

struct TagSearchTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tags-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func makeIndex() throws -> SearchIndex {
        let index = try SearchIndex(url: folder.appendingPathComponent(SearchIndex.fileName))
        let docs = [
            (1, "Rentenbescheid der DRV Bund über die Altersrente"),
            (2, "Deutsche Rentenversicherung Renteninformation 2026"),
            (3, "DRV Mitteilung zur Rente und Krankenversicherung"),
            (4, "Stromrechnung Stadtwerke München"),
            (5, "Witwenrente Bescheid"),
        ]
        for (n, text) in docs {
            try index.add(number: n, date: Date(), url: folder.appendingPathComponent("\(n).pdf"), pages: 1, text: text,
                          meta: n == 3 ? DocumentMetadata(number: 3, documentDate: Date(), dateSource: .today, titleSource: .none,
                                                          source: .pdf, issues: [.noDate]) : nil)
        }
        return index
    }

    @Test func exampleTag() throws {
        let index = try makeIndex()
        let query = "(\"Rente\" AND \"DRV\") OR \"Rentenversicherung\""
        #expect(try index.search("", tagQueries: [query]).map(\.number) == [3, 2])
        #expect(try index.count(tagQuery: query) == 2)
    }

    @Test func exactVersusWildcards() throws {
        let index = try makeIndex()
        #expect(try index.count(tagQuery: "Rente") == 1)          // nur exakt „Rente“
        #expect(Set(try index.search("", tagQueries: ["rente*"]).map(\.number)) == [1, 2, 3])
        #expect(Set(try index.search("", tagQueries: ["*rente"]).map(\.number)) == [1, 3, 5])  // Altersrente, Rente, Witwenrente
        #expect(Set(try index.search("", tagQueries: ["*rente*"]).map(\.number)) == [1, 2, 3, 5])
        #expect(try index.search("", tagQueries: ["*gibtsnicht"]).isEmpty)
    }

    @Test func tagsAndSearchAreAnded() throws {
        let index = try makeIndex()
        #expect(Set(try index.search("", tagQueries: ["DRV", "rente*"]).map(\.number)) == [1, 3])
        #expect(try index.search("kranken", tagQueries: ["DRV", "rente*"]).map(\.number) == [3])
        #expect(try index.search("", tagQueries: ["rente*"], onlyIssues: true).map(\.number) == [3])
    }

    @Test func tagWordsAreNotHighlighted() throws {
        let index = try makeIndex()
        // Tag „DRV“, Suchwort „mitteil“: nur das Suchwort wird markiert
        let hit = try #require(try index.search("mitteil", tagQueries: ["DRV"]).first)
        #expect(hit.snippet.contains("\u{1}Mitteilung\u{2}"))
        #expect(!hit.snippet.contains("\u{1}DRV"))
        // nur Tag: gar keine Markierung
        #expect(try index.search("", tagQueries: ["DRV"]).allSatisfy { !$0.snippet.contains("\u{1}") })
    }

    @Test func invalidTagThrows() throws {
        let index = try makeIndex()
        #expect(throws: TagQuery.ParseError.self) { try index.search("", tagQueries: ["(Rente"]) }
    }

    @Test func storeRoundTrip() throws {
        let store = TagStore(folder: folder)
        var tag = Tag(name: "Rente", query: "rente* OR DRV")
        try store.add(tag)
        try store.add(Tag(name: "Strom", query: "Stromrechnung"))
        tag.query = "DRV"
        try store.update(tag)
        let reloaded = TagStore(folder: folder)
        #expect(reloaded.all.map(\.name) == ["Rente", "Strom"])
        #expect(reloaded.all.first?.query == "DRV")
        try reloaded.remove(id: tag.id)
        #expect(TagStore(folder: folder).all.map(\.name) == ["Strom"])
    }

    /// ~3000 Dokumente: Zählen und kombinierte Suche müssen schnell bleiben.
    @Test func performanceWithThousandsOfDocuments() throws {
        let index = try SearchIndex(url: folder.appendingPathComponent("gross.sqlite"))
        let words = ["Rente", "Bescheid", "Stromrechnung", "Versicherung", "Kfz", "Mietvertrag", "Kontoauszug", "Steuer",
                     "Altersrente", "Rentenversicherung", "DRV", "Finanzamt", "Arzt", "Rechnung", "Mahnung"]
        for n in 1...3000 {
            let text = (0..<200).map { i in words[(n * 7 + i * 13) % words.count] + String(i % 50) }.joined(separator: " ")
            try index.add(number: n, date: Date(), url: folder.appendingPathComponent("\(n).pdf"), pages: 3,
                          text: text + " " + words[n % words.count])
        }
        let clock = ContinuousClock()
        let countTime = try clock.measure { _ = try index.count(tagQuery: "(\"Rente\" AND \"DRV\") OR *versicherung*") }
        let searchTime = try clock.measure { _ = try index.search("rech", tagQueries: ["rente* OR DRV", "NOT_VORHANDEN OR Steuer"]) }
        print("3000 Dokumente – Zählen: \(countTime), kombinierte Suche: \(searchTime)")
        #expect(countTime < .milliseconds(200))
        #expect(searchTime < .milliseconds(1000))
    }
}
