import Foundation

/// Erkennt anhand gedruckter Seitenzahlen („Seite 2 von 4“, „- 2 -“ …), ob die Seiten eines Dokuments
/// in der richtigen Reihenfolge liegen. Bewusst vorsichtig: nackte Zahlen zählen nicht, und
/// umsortiert wird nur, wenn die Nummern eine eindeutige, lückenlose Folge ergeben.
public enum PageNumbering {
    public enum Result: Equatable, Sendable {
        /// keine verwertbaren Seitenzahlen
        case none
        /// Seitenzahlen passen zur Reihenfolge
        case inOrder
        /// eindeutige andere Reihenfolge: Indizes (ab 0) der bisherigen Seiten in neuer Reihenfolge
        case reorder([Int])
        /// Seitenzahlen passen nicht, sind aber nicht eindeutig (gefundene Nummer je Seite)
        case uncertain([Int?])
    }

    /// Zeilen am Seitenanfang und -ende, in denen Seitenzahlen gesucht werden.
    static let edgeLines = 4

    public static func analyze(pageTexts: [String]) -> Result {
        guard pageTexts.count >= 2 else { return .none }
        let found = pageTexts.map(pageNumber(in:))
        let numbers = found.map { $0?.number }
        let known = numbers.compactMap { $0 }
        // mindestens zwei Nummern, sonst ist nichts zu beurteilen
        guard known.count >= 2 else { return .none }

        let totals = Set(found.compactMap { $0?.total })
        let ascending = zip(known, known.dropFirst()).allSatisfy { $0 < $1 }
        if ascending, totals.count <= 1 { return .inOrder }

        let count = pageTexts.count
        let distinct = Set(known).count == known.count
        let missing = count - known.count
        guard distinct, totals.count <= 1, missing <= 1 else { return .uncertain(numbers) }
        if let total = totals.first, total != count { return .uncertain(numbers) }

        // lückenlose Folge; eine Seite ohne Nummer füllt die einzige Lücke (meist Seite 1)
        let low = known.min()!, high = known.max()!
        var assigned = numbers
        if missing == 1 {
            let range = high - low + 1
            let gap: Int
            if range == count {
                guard let inner = (low...high).first(where: { !known.contains($0) }) else { return .uncertain(numbers) }
                gap = inner
            } else if range == count - 1, low == 2, numbers[0] == nil {
                // unnummerierte erste Seite (Anschreiben) bleibt vorn; eine unnummerierte Seite
                // weiter hinten könnte auch eine Anlage sein → nicht raten
                gap = 1
            } else {
                return .uncertain(numbers)
            }
            assigned = numbers.map { $0 ?? gap }
        } else if high - low + 1 != count {
            return .uncertain(numbers)
        }
        let order = assigned.enumerated().sorted { $0.element! < $1.element! }.map(\.offset)
        return order == Array(0..<count) ? .inOrder : .reorder(order)
    }

    /// Für eine Umsortierung `order` (Originalindizes in neuer Reihenfolge): die neue Seitennummer jeder
    /// Originalseite, in Originalreihenfolge – also so, wie die Seiten vorher lagen, z. B. 1, 3, 2.
    public static func originalSequence(_ order: [Int]) -> [Int] {
        var result = Array(repeating: 0, count: order.count)
        for (position, original) in order.enumerated() where original < order.count { result[original] = position + 1 }
        return result
    }

    // MARK: Seitenzahl einer Seite

    public struct Found: Equatable, Sendable {
        public var number: Int
        public var total: Int?
    }

    private static let patterns: [NSRegularExpression] = [
        // Seite 2 von 5 · Seite: 2/5 · Seite 2 · S. 2 · Blatt 2 · Page 2 of 5 · Page 2
        #"(?i)\b(?:seite|blatt|page|s\.)\s*:?\s*(\d{1,3})(?:\s*(?:von|of|/)\s*(\d{1,3}))?\b"#,
        // Zeile nur aus 2/5
        #"^\s*(\d{1,3})\s*/\s*(\d{1,3})\s*$"#,
        // - 2 -  ·  – 2 –
        #"^\s*[-–—]\s*(\d{1,3})\s*[-–—]\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }

    /// Gedruckte Seitenzahl einer Seite (Kopf- oder Fußzeile), falls vorhanden.
    public static func pageNumber(in text: String) -> Found? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let edge = lines.count <= edgeLines * 2 ? lines : Array(lines.prefix(edgeLines) + lines.suffix(edgeLines))
        for line in edge.reversed() {  // Fußzeile zuerst – dort stehen Seitenzahlen am häufigsten
            let range = NSRange(line.startIndex..., in: line)
            for pattern in patterns {
                guard let match = pattern.firstMatch(in: line, range: range),
                      let numberRange = Range(match.range(at: 1), in: line),
                      let number = Int(line[numberRange]), number >= 1 else { continue }
                var total: Int?
                if match.numberOfRanges > 2, let totalRange = Range(match.range(at: 2), in: line) {
                    total = Int(line[totalRange])
                    // „2/5“ ohne Wort davor nur, wenn es plausibel ist
                    if let t = total, t < number { continue }
                }
                return Found(number: number, total: total)
            }
        }
        return nil
    }
}
