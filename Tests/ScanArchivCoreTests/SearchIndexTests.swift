import Foundation
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
        try index.add(number: 123, date: Date(), url: folder.appendingPathComponent("c.pdf"), pages: 4, text: "Kfz-Versicherung Rechnung 2026")
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
}
