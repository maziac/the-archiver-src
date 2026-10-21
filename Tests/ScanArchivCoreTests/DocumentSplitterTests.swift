import CoreGraphics
import Foundation
import Testing
@testable import ScanArchivCore

@Suite("Stapel aufteilen")
struct DocumentSplitterTests {
    typealias Page = DocumentSplitter.Page
    typealias Sheet = DocumentSplitter.Sheet

    static func line(_ text: String, x: Double = 0.1, y: Double) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y - 0.005, width: 0.5, height: 0.01))
    }

    static func body(from top: Double, lines: Int = 8) -> [OCRLine] {
        (0..<lines).map { line("Lorem ipsum dolor sit amet, consectetur adipiscing elit \($0)", y: top - Double($0) * 0.03) }
    }

    static func footer(_ sender: String, page: String?) -> [OCRLine] {
        [line("\(sender) GmbH · Hauptstraße 1 · IBAN DE12 3456 7890 · Amtsgericht Musterstadt HRB 1234", y: 0.05)]
            + (page.map { [line($0, x: 0.45, y: 0.03)] } ?? [])
    }

    /// Erste Seite eines Briefes mit Briefkopf, Anschriftfeld, Datum, Betreff und Anrede.
    static func firstPage(_ sender: String = "Stadtwerke Musterstadt", page: String? = nil, closing: Bool = true) -> Page {
        var lines = [
            line("\(sender) GmbH", x: 0.6, y: 0.95),
            line("\(sender) · Hauptstraße 1 · 12345 Musterstadt", y: 0.83),
            line("Herrn Max Mustermann", y: 0.80),
            line("Gartenweg 5", y: 0.78),
            line("54321 Beispielort", y: 0.76),
            line("Musterstadt, 12.03.2025", x: 0.6, y: 0.68),
            line("Betreff: Ihre Jahresabrechnung", y: 0.63),
            line("Sehr geehrter Herr Mustermann,", y: 0.58),
        ] + body(from: 0.54)
        if closing { lines.append(line("Mit freundlichen Grüßen", y: 0.25)) }
        return Page(lines: lines + footer(sender, page: page), blank: false)
    }

    /// Folgeseite ohne Merkmale einer ersten Seite.
    static func nextPage(_ sender: String = "Stadtwerke Musterstadt", page: String? = nil, closing: Bool = false) -> Page {
        var lines = body(from: 0.9, lines: 20)
        if closing { lines.append(line("Mit freundlichen Grüßen", y: 0.25)) }
        return Page(lines: lines + footer(sender, page: page), blank: false)
    }

    static let blank = Page(lines: [], blank: true)

    static func splits(_ sheets: [Sheet]) -> [Bool] {
        DocumentSplitter.analyze(sheets).gaps.map(\.split)
    }

    @Test("Drei einseitige Briefe, Rückseiten leer")
    func threeSingleLetters() {
        let sheets = ["Stadtwerke", "DAK Gesundheit", "Finanzamt"].map { Sheet(front: Self.firstPage($0), back: Self.blank) }
        let analysis = DocumentSplitter.analyze(sheets)
        #expect(analysis.gaps.map(\.split) == [true, true])
        #expect(analysis.gaps.allSatisfy { $0.confidence == .certain })
        #expect(analysis.separators.isEmpty)
    }

    @Test("Zwei Briefe desselben Absenders")
    func sameSender() {
        let sheets = [Sheet(front: Self.firstPage()), Sheet(front: Self.firstPage())]
        #expect(Self.splits(sheets) == [true])
    }

    @Test("Seitenzahlen: beidseitiger Brief, dann einseitiger")
    func numberedDuplex() {
        let sheets = [
            Sheet(front: Self.firstPage(page: "Seite 1 von 4", closing: false), back: Self.nextPage(page: "Seite 2 von 4")),
            Sheet(front: Self.nextPage(page: "Seite 3 von 4"), back: Self.nextPage(page: "Seite 4 von 4", closing: true)),
            Sheet(front: Self.firstPage("Finanzamt", page: "Seite 1 von 1"), back: Self.blank),
        ]
        let analysis = DocumentSplitter.analyze(sheets)
        #expect(analysis.gaps.map(\.split) == [false, true])
        #expect(analysis.gaps.allSatisfy { $0.confidence == .certain })
    }

    @Test("Mehrseitiger Brief ohne Seitenzahlen")
    func unnumberedLetter() {
        let sheets = [
            Sheet(front: Self.firstPage(closing: false)),
            Sheet(front: Self.nextPage()),
            Sheet(front: Self.nextPage(closing: true)),
            Sheet(front: Self.firstPage("Finanzamt")),
        ]
        #expect(Self.splits(sheets) == [false, false, true])
    }

    @Test("Folgeseite mit Nummer nach unnummerierter erster Seite")
    func numberedContinuation() {
        let sheets = [Sheet(front: Self.firstPage(closing: false)), Sheet(front: Self.nextPage(page: "- 2 -"))]
        let gap = DocumentSplitter.analyze(sheets).gaps[0]
        #expect(gap.split == false)
        #expect(gap.confidence == .likely)
    }

    @Test("Vertauschte Blätter werden nicht getrennt, aber sortiert")
    func swappedSheets() {
        let letter = [
            Sheet(front: Self.firstPage(page: "Seite 1 von 3", closing: false)),
            Sheet(front: Self.nextPage(page: "Seite 3 von 3", closing: true)),
            Sheet(front: Self.nextPage(page: "Seite 2 von 3")),
        ]
        let sheets = letter + [Sheet(front: Self.firstPage("Finanzamt"))]
        #expect(Self.splits(sheets) == [false, false, true])
        #expect(DocumentSplitter.sheetOrder(letter) == [0, 2, 1])
    }

    @Test("Blattweise sortieren: Vorder- und Rückseite bleiben zusammen")
    func sheetOrderDuplex() {
        let sheets = [
            Sheet(front: Self.nextPage(page: "Seite 3"), back: Self.nextPage(page: "Seite 4")),
            Sheet(front: Self.firstPage(page: "Seite 1", closing: false), back: Self.nextPage(page: "Seite 2")),
        ]
        #expect(DocumentSplitter.sheetOrder(sheets) == [1, 0])
        // Rückseite passt nicht zur Vorderseite → nicht raten
        let broken = [
            Sheet(front: Self.nextPage(page: "Seite 3"), back: Self.nextPage(page: "Seite 2")),
            Sheet(front: Self.firstPage(page: "Seite 1", closing: false), back: Self.nextPage(page: "Seite 4")),
        ]
        #expect(DocumentSplitter.sheetOrder(broken) == nil)
        // richtige Reihenfolge → nichts zu tun
        #expect(DocumentSplitter.sheetOrder(Array(sheets.reversed())) == nil)
    }

    @Test("Unnummeriertes Anschreiben bleibt vorn")
    func unnumberedCoverSheet() {
        let sheets = [
            Sheet(front: Self.firstPage(closing: false)),
            Sheet(front: Self.nextPage(page: "Seite 3")),
            Sheet(front: Self.nextPage(page: "Seite 2")),
        ]
        #expect(DocumentSplitter.sheetOrder(sheets) == [0, 2, 1])
    }

    @Test("Leeres Blatt ist Trennblatt")
    func separatorSheet() {
        let sheets = [
            Sheet(front: Self.firstPage(closing: false), back: Self.blank),
            Sheet(front: Self.blank, back: Self.blank),
            Sheet(front: Self.nextPage(), back: Self.blank),
        ]
        let analysis = DocumentSplitter.analyze(sheets)
        #expect(analysis.separators == [1])
        #expect(analysis.gaps.map(\.split) == [true, true])
        let docs = DocumentSplitter.documents(sheetCount: 3, splits: analysis.gaps.map(\.split), separators: analysis.separators)
        #expect(docs == [[0], [2]])
    }

    @Test("Anlage nach Grußformel: unsicher, bleibt beim Brief")
    func attachment() {
        let sheets = [Sheet(front: Self.firstPage(closing: true)), Sheet(front: Self.nextPage("Formularverlag"))]
        let gap = DocumentSplitter.analyze(sheets).gaps[0]
        #expect(gap.split == false)
        #expect(gap.confidence == .uncertain)
    }

    @Test("Vollständiges Dokument, danach Blatt ohne Merkmale")
    func afterCompleteDocument() {
        let sheets = [
            Sheet(front: Self.firstPage(page: "Seite 1 von 1")),
            Sheet(front: Self.nextPage()),
        ]
        let gap = DocumentSplitter.analyze(sheets).gaps[0]
        #expect(gap.split == true)
        #expect(gap.confidence == .uncertain)
    }

    @Test("Dokumente aus Trennstellen")
    func documentsFromSplits() {
        #expect(DocumentSplitter.documents(sheetCount: 4, splits: [false, true, false], separators: []) == [[0, 1], [2, 3]])
        #expect(DocumentSplitter.documents(sheetCount: 3, splits: [false, false], separators: []) == [[0, 1, 2]])
        #expect(DocumentSplitter.documents(sheetCount: 3, splits: [true, true], separators: [0]) == [[1], [2]])
        #expect(DocumentSplitter.documents(sheetCount: 1, splits: [], separators: []) == [[0]])
    }
}
