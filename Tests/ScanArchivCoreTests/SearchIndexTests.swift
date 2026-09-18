import Foundation
import SQLite3
import Testing
@testable import ScanArchivCore

struct SearchIndexTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScanArchivIndex-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func makeIndex() throws -> SearchIndex {
        let index = try SearchIndex(url: folder.appendingPathComponent(SearchIndex.fileName))
        try index.add(number: 1, date: Date(), url: folder.appendingPathComponent("a.pdf"), pages: 2, text: "Stromrechnung der Stadtwerke München")
        try index.add(number: 2, date: Date(), url: folder.appendingPathComponent("b.pdf"), pages: 1, text: "Mietvertrag Wohnung München")
        try index.add(number: 123, date: Date(), url: folder.appendingPathComponent("c.pdf"), pages: 4, text: "Kfz-Versicherung Rechnung 2026",
                      title: "Allianz Beitragsrechnung", summary: "Jahresbeitrag für das Auto")
        return index
    }

    @Test func emptyQueryListsAllNewestFirst() throws {
        #expect(try makeIndex().search("").map(\.number) == [123, 2, 1])
    }

    @Test func keywordsAreAndCombinedAndPrefix() throws {
        let index = try makeIndex()
        #expect(try index.search("münchen").map(\.number) == [2, 1])
        #expect(try index.search("München strom").map(\.number) == [1])
        #expect(try index.search("rechn").map(\.number) == [123])  // Präfix
        #expect(try index.search("muenchen xyz").isEmpty)
    }

    @Test func diacriticsAreIgnored() throws {
        #expect(try makeIndex().search("munchen").count == 2)
    }

    @Test func numberSearch() throws {
        let index = try makeIndex()
        #expect(try index.search("000123").map(\.number) == [123])
        #expect(try index.search("123").map(\.number) == [123])
    }

    @Test func snippetMarksHit() throws {
        let hit = try #require(try makeIndex().search("Mietvertrag").first)
        #expect(hit.snippet.contains("\u{1}Mietvertrag\u{2}"))
    }

    @Test func hostileInputIsSafe() throws {
        #expect(try makeIndex().search("\"AND OR NOT ( * :").isEmpty)
    }

    @Test func syncRemovesMissingFiles() throws {
        let index = try makeIndex()
        try index.sync(folder: folder)  // a/b/c.pdf existieren nicht auf der Platte
        #expect(try index.search("").isEmpty)
    }

    @Test func titleAndSummaryAreSearchable() throws {
        let index = try makeIndex()
        #expect(try index.search("allianz").map(\.number) == [123])
        #expect(try index.search("jahresbeitrag auto").map(\.number) == [123])
        let record = try #require(try index.search("allianz").first)
        #expect(record.title == "Allianz Beitragsrechnung")
        #expect(record.summary == "Jahresbeitrag für das Auto")
    }

    @Test func updateAndMissingTitles() throws {
        let index = try makeIndex()
        #expect(Set(try index.recordsWithoutTitle().map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["a.pdf", "b.pdf"])
        let newURL = folder.appendingPathComponent("a2.pdf")
        try index.update(oldPath: folder.appendingPathComponent("a.pdf").path, newURL: newURL, date: Date(), title: "Stromrechnung", summary: "SWM")
        #expect(try index.search("stromrechnung").first?.path == newURL.path)
        #expect(try index.recordsWithoutTitle().count == 1)
    }

    @Test func migratesOldSchema() throws {
        let url = folder.appendingPathComponent("old.sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE VIRTUAL TABLE docs USING fts5(number, date UNINDEXED, path UNINDEXED, pages UNINDEXED, text)", nil, nil, nil)
        sqlite3_close(db)
        let index = try SearchIndex(url: url)
        try index.add(number: 1, date: Date(), url: folder.appendingPathComponent("x.pdf"), pages: 1, text: "t", title: "Titel")
        #expect(try index.search("titel").count == 1)
    }
}
