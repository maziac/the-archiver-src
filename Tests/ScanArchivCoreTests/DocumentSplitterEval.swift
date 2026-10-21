import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

/// Misst die Aufteilung am echten Archiv: je drei aufeinanderfolgende Dokumente werden zu einem
/// künstlichen Stapel (eine Seite = ein Blatt) zusammengesetzt und wieder aufgeteilt.
/// Läuft nur mit `SCANARCHIV_EVAL=<Archivordner> swift test --filter DocumentSplitterEval`.
@Suite("Stapel aufteilen – Messung am Archiv")
struct DocumentSplitterEval {
    static let archivePath = ProcessInfo.processInfo.environment["SCANARCHIV_EVAL"]

    struct Doc {
        var number: Int
        var scanned: Bool
        var pages: [DocumentSplitter.Page]
    }

    /// Seiten mit Textebene als OCR-Zeilen (normiert, Ursprung unten links); Seiten ohne Text fallen weg.
    static func load(_ url: URL) -> Doc? {
        guard let parsed = Archive.parse(fileName: url.lastPathComponent),
              let pdf = PDFDocument(url: url) else { return nil }
        var pages: [DocumentSplitter.Page] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0,
                  let selection = page.selection(for: bounds) else { continue }
            var lines: [OCRLine] = []
            for lineSelection in selection.selectionsByLine() {
                let text = (lineSelection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let r = lineSelection.bounds(for: page)
                lines.append(OCRLine(text: text, box: CGRect(
                    x: (r.minX - bounds.minX) / bounds.width, y: (r.minY - bounds.minY) / bounds.height,
                    width: r.width / bounds.width, height: r.height / bounds.height)))
            }
            guard DocumentIssue.hasText(lines.map(\.text).joined(separator: "\n")) else { continue }
            pages.append(.init(lines: lines, blank: false))
        }
        guard !pages.isEmpty else { return nil }
        return Doc(number: parsed.number, scanned: PDFMetadata.read(pdf)?.source == .scan, pages: pages)
    }

    struct Tally {
        var gaps = 0, correct = 0
        var byConfidence: [DocumentSplitter.Confidence: (total: Int, correct: Int)] = [:]
        var stacks = 0, stacksCorrect = 0
        var missedSplits = 0, falseSplits = 0

        func report(_ name: String) -> String {
            func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.1f %%", 100 * Double(a) / Double(b)) }
            var out = "\(name): Lücken \(correct)/\(gaps) richtig (\(pct(correct, gaps))), "
                + "Stapel \(stacksCorrect)/\(stacks) komplett richtig (\(pct(stacksCorrect, stacks))), "
                + "verpasste Trennungen \(missedSplits), falsche Trennungen \(falseSplits)"
            for c in DocumentSplitter.Confidence.allCases.reversed() {
                let v = byConfidence[c] ?? (0, 0)
                out += "\n  \(c): \(v.correct)/\(v.total) richtig (\(pct(v.correct, v.total)))"
            }
            return out
        }
    }

    @Test(.enabled(if: archivePath != nil))
    func measure() throws {
        let folder = URL(fileURLWithPath: try #require(Self.archivePath))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }
        let docs = files.compactMap(Self.load).sorted { $0.number < $1.number }
        print("Dokumente mit Text: \(docs.count), davon gescannt: \(docs.filter(\.scanned).count)")

        var misses: [String] = []
        func run(_ docs: [Doc], stackSize: Int) -> Tally {
            var tally = Tally()
            for start in stride(from: 0, to: docs.count - stackSize + 1, by: stackSize) {
                let stack = Array(docs[start..<start + stackSize])
                let sheets = stack.flatMap { $0.pages.map { DocumentSplitter.Sheet(front: $0) } }
                var truth: [Bool] = []
                var owner: [Int] = []
                for (d, doc) in stack.enumerated() {
                    for p in doc.pages.indices {
                        if !owner.isEmpty { truth.append(p == 0) }
                        owner.append(d)
                    }
                }
                let gaps = DocumentSplitter.analyze(sheets).gaps
                var allRight = true
                for (i, gap) in gaps.enumerated() {
                    let right = gap.split == truth[i]
                    tally.gaps += 1
                    if right { tally.correct += 1 } else {
                        allRight = false
                        if truth[i] { tally.missedSplits += 1 } else { tally.falseSplits += 1 }
                        let doc = stack[owner[i + 1]]
                        misses.append("Nr. \(doc.number) vor Seite \(i + 1 - owner.firstIndex(of: owner[i + 1])! + 1): "
                                      + "\(gap.split ? "getrennt" : "nicht getrennt") [\(gap.confidence)] \(gap.reason)")
                    }
                    var bucket = tally.byConfidence[gap.confidence] ?? (0, 0)
                    bucket.total += 1
                    if right { bucket.correct += 1 }
                    tally.byConfidence[gap.confidence] = bucket
                }
                tally.stacks += 1
                if allRight { tally.stacksCorrect += 1 }
            }
            return tally
        }

        let all = run(docs, stackSize: 3)
        let failuresAll = misses
        misses = []
        let scans = run(docs.filter(\.scanned), stackSize: 3)
        print(all.report("Alle Dokumente"))
        print(scans.report("Nur Scans"))
        // Reihenfolge: archivierte Dokumente liegen richtig, eine Umsortierung wäre ein Fehler
        let multi = docs.filter { $0.pages.count >= 2 }
        let wrongOrder = multi.filter { DocumentSplitter.sheetOrder($0.pages.map { .init(front: $0) }) != nil }
        print("Reihenfolge: \(wrongOrder.count) von \(multi.count) mehrseitigen Dokumenten würden umsortiert"
              + (wrongOrder.isEmpty ? "" : " (Nr. \(wrongOrder.map { String($0.number) }.joined(separator: ", ")))"))
        print("Fehler (alle):\n" + failuresAll.joined(separator: "\n"))
    }
}
