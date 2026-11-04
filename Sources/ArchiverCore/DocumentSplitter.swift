import Foundation

/// Teilt einen Stapel gescannter Blätter in einzelne Dokumente (Briefe) auf.
///
/// Getrennt wird nur zwischen Blättern – ein neuer Brief beginnt immer auf einem neuen Blatt.
/// Für jede Lücke zwischen zwei Blättern wird entschieden: neues Dokument oder Fortsetzung, samt
/// Sicherheit. Grundlage sind gedruckte Seitenzahlen (`PageNumbering`), typische Merkmale einer
/// ersten Briefseite (Anschriftfeld, Anrede, Betreff, Datum im Kopf), Grußformeln und die Ähnlichkeit
/// von Kopf-/Fußzeilen. Ein beidseitig leeres Blatt gilt als Trennblatt.
public enum DocumentSplitter {
    /// Eine Seite: OCR-Zeilen (normiert, Ursprung unten links) und ob sie leer ist.
    public struct Page: Sendable {
        public var lines: [OCRLine]
        public var blank: Bool

        public init(lines: [OCRLine], blank: Bool) {
            self.lines = lines
            self.blank = blank
        }
    }

    /// Ein Blatt; `back` fehlt bei einseitigem Scan.
    public struct Sheet: Sendable {
        public var front: Page
        public var back: Page?

        public init(front: Page, back: Page? = nil) {
            self.front = front
            self.back = back
        }

        /// Seiten mit Inhalt in Lesereihenfolge
        var contentPages: [Page] { ([front] + (back.map { [$0] } ?? [])).filter { !$0.blank } }
        var isSeparator: Bool { contentPages.isEmpty }
    }

    public enum Confidence: Int, Sendable, Comparable, CaseIterable {
        case uncertain, likely, certain

        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    /// Entscheidung für die Lücke vor einem Blatt.
    public struct Gap: Sendable, Equatable {
        /// hier beginnt ein neues Dokument
        public var split: Bool
        public var confidence: Confidence
        /// Begründung (für Log und Tooltip)
        public var reason: String

        public init(split: Bool, confidence: Confidence, reason: String) {
            self.split = split
            self.confidence = confidence
            self.reason = reason
        }
    }

    public struct Analysis: Sendable, Equatable {
        /// Indizes der Trennblätter (werden verworfen)
        public var separators: Set<Int>
        /// `gaps[i]` = Lücke zwischen Blatt i und i + 1 (Scanreihenfolge)
        public var gaps: [Gap]
    }

    // MARK: Aufteilen

    public static func analyze(_ sheets: [Sheet]) -> Analysis {
        let features = sheets.map(SheetFeatures.init)
        let separators = Set(sheets.indices.filter { sheets[$0].isSeparator })
        var gaps: [Gap] = []
        var group = GroupState()
        for i in sheets.indices {
            if i > 0 {
                let gap: Gap
                if separators.contains(i - 1) || separators.contains(i) {
                    gap = Gap(split: true, confidence: .certain, reason: "Trennblatt")
                } else {
                    gap = decide(group: group, previous: features[i - 1], next: features[i])
                }
                gaps.append(gap)
                if gap.split { group = GroupState() }
            }
            if !separators.contains(i) { group.add(features[i]) }
        }
        return Analysis(separators: separators, gaps: gaps)
    }

    /// Dokumente als Blattindizes (Scanreihenfolge) aus den Trennstellen; Trennblätter fallen weg.
    public static func documents(sheetCount: Int, splits: [Bool], separators: Set<Int>) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for i in 0..<sheetCount {
            if i > 0, i - 1 < splits.count, splits[i - 1], !current.isEmpty {
                result.append(current)
                current = []
            }
            if !separators.contains(i) { current.append(i) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Reihenfolge der Blätter eines Dokuments laut Seitenzahlen (Originalindizes in neuer Reihenfolge),
    /// oder `nil`, wenn die Seitenzahlen keine eindeutige andere Reihenfolge ergeben.
    /// Sortiert blattweise – Vorder- und Rückseite bleiben zusammen.
    public static func sheetOrder(_ sheets: [Sheet]) -> [Int]? {
        guard sheets.count >= 2 else { return nil }
        let features = sheets.map(SheetFeatures.init)
        var keys: [Int?] = []
        for f in features {
            guard f.consistent else { return nil }
            keys.append(f.numbers.first.map { $0.number - $0.offset })
        }
        let totals = Set(features.flatMap { $0.numbers.compactMap(\.total) })
        let known = keys.compactMap { $0 }
        guard totals.count <= 1, known.count >= 2, Set(known).count == known.count else { return nil }
        // ein Blatt ohne Nummer nur als erstes (Anschreiben); weiter hinten könnte es eine Anlage sein
        let unnumbered = keys.indices.filter { keys[$0] == nil }
        if unnumbered.count > 1 { return nil }
        if let u = unnumbered.first {
            guard u == 0, known.min()! > 1 else { return nil }
            keys[0] = 0
        }
        let order = keys.indices.sorted { keys[$0]! < keys[$1]! }
        return order == Array(sheets.indices) ? nil : order
    }

    // MARK: Entscheidung je Lücke

    /// Seitenzahlen des bisherigen Dokuments
    struct GroupState {
        var numbers: Set<Int> = []
        var total: Int?
        var sheets = 0

        mutating func add(_ f: SheetFeatures) {
            sheets += 1
            numbers.formUnion(f.numbers.map(\.number))
            if total == nil { total = f.numbers.compactMap(\.total).first }
        }

        var complete: Bool {
            guard let total else { return false }
            return Set(1...max(total, 1)).isSubset(of: numbers)
        }
    }

    static func decide(group: GroupState, previous: SheetFeatures, next: SheetFeatures) -> Gap {
        let first = next.firstPageScore
        let similar = previous.edgeTokens.isEmpty || next.edgeTokens.isEmpty
            ? false : jaccard(previous.edgeTokens, next.edgeTokens) >= 0.35

        // 1. gedruckte Seitenzahlen
        if let n = next.numbers.first {
            let total = next.numbers.compactMap(\.total).first
            if let total, let groupTotal = group.total, total != groupTotal {
                return Gap(split: true, confidence: .certain, reason: "andere Seitenzahl gesamt (\(total) statt \(groupTotal))")
            }
            if group.complete {
                return Gap(split: true, confidence: .certain, reason: "vorheriges Dokument vollständig")
            }
            let fresh = next.numbers.allSatisfy { !group.numbers.contains($0.number) }
            // vertauschte Blätter: gleiche Gesamtzahl, Nummer fehlt noch → gehört dazu
            if let total, total == group.total, fresh {
                return Gap(split: false, confidence: .certain, reason: "Seite \(n.number) von \(total)")
            }
            // erste Seitenzahl, zurückgerechnet auf die Vorderseite
            let start = n.number - n.offset
            if start == 1 {
                return Gap(split: true, confidence: .certain, reason: "Seite 1")
            }
            if !fresh {
                return Gap(split: true, confidence: .likely, reason: "Seite \(n.number) gibt es schon")
            }
            if let high = group.numbers.max(), start == high + 1 {
                return Gap(split: false, confidence: .certain, reason: "Seite \(n.number) folgt auf \(high)")
            }
            if group.numbers.isEmpty, start == 2 * group.sheets + 1 || start == group.sheets + 1 {
                return Gap(split: false, confidence: first >= 3 ? .uncertain : .likely,
                           reason: "Seite \(n.number) nach unnummerierter erster Seite")
            }
            return Gap(split: false, confidence: .uncertain, reason: "Seite \(n.number) passt nicht genau")
        }

        // 2. keine Seitenzahl auf dem Blatt, aber im bisherigen Dokument
        if let total = group.total {
            if group.complete {
                return first >= 2
                    ? Gap(split: true, confidence: .certain, reason: "vorheriges Dokument vollständig, erste Seite")
                    : Gap(split: true, confidence: .uncertain, reason: "vorheriges Dokument vollständig – Anlage?")
            }
            return first >= 3
                ? Gap(split: true, confidence: .uncertain, reason: "erste Seite, obwohl \(total) Seiten angekündigt")
                : Gap(split: false, confidence: .likely, reason: "Dokument hat \(total) Seiten, noch nicht alle")
        }

        // 3. Merkmale einer ersten Seite
        if first >= 3 {
            return Gap(split: true, confidence: previous.closing || !similar ? .certain : .likely, reason: "erste Seite (\(next.firstPageReasons))")
        }
        if first == 2 {
            return Gap(split: true, confidence: previous.closing ? .likely : .uncertain, reason: "vermutlich erste Seite (\(next.firstPageReasons))")
        }
        if previous.closing {
            return Gap(split: false, confidence: .uncertain, reason: "vorheriges endet mit Gruß – Anlage oder neues Dokument?")
        }
        return Gap(split: false, confidence: first == 0 && similar ? .likely : .uncertain,
                   reason: similar ? "ähnliche Kopf-/Fußzeile" : "keine Merkmale einer ersten Seite")
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
    }

    // MARK: Merkmale

    struct Number: Equatable {
        var number: Int
        var total: Int?
        /// Seite innerhalb des Blatts (0 = Vorderseite)
        var offset: Int
    }

    struct SheetFeatures {
        /// gedruckte Seitenzahlen der Seiten mit Inhalt
        var numbers: [Number] = []
        /// Seitenzahlen von Vorder- und Rückseite passen zusammen
        var consistent = true
        /// Punkte für „erste Seite eines Briefes“ (Seite mit Inhalt vorn auf dem Blatt)
        var firstPageScore = 0
        var firstPageReasons = ""
        /// letzte Seite enthält eine Grußformel
        var closing = false
        /// Wörter aus Kopf- und Fußzeile (Absender, Bankverbindung …)
        var edgeTokens: Set<String> = []

        init(_ sheet: Sheet) {
            let pages = sheet.contentPages
            let numberedPages: [(offset: Int, page: Page)] = sheet.back.map { [(0, sheet.front), (1, $0)] } ?? [(0, sheet.front)]
            for (offset, page) in numberedPages where !page.blank {
                if let found = PageNumbering.pageNumber(in: DocumentSplitter.text(page)) {
                    numbers.append(Number(number: found.number, total: found.total, offset: offset))
                }
            }
            if numbers.count == 2 {
                consistent = numbers[1].number == numbers[0].number + 1
                    && (numbers[0].total == nil || numbers[1].total == nil || numbers[0].total == numbers[1].total)
            }
            if let firstPage = pages.first {
                (firstPageScore, firstPageReasons) = DocumentSplitter.firstPageScore(firstPage)
                edgeTokens = DocumentSplitter.edgeTokens(firstPage)
            }
            if let last = pages.last {
                closing = DocumentSplitter.closingPattern.firstMatch(in: DocumentSplitter.text(last)) != nil
            }
        }
    }

    /// Seitentext von oben nach unten, damit Kopf- und Fußzeile am Anfang bzw. Ende stehen.
    static func text(_ page: Page) -> String {
        page.lines.sorted { $0.box.midY > $1.box.midY }.map(\.text).joined(separator: "\n")
    }

    /// PLZ + Ort, z. B. „12345 Musterstadt“ oder „D-12345 Musterstadt“
    static let postalPattern = try! NSRegularExpression(pattern: #"(?<!\d)(?:D\s?-\s?)?\d{5}\s+\p{Lu}\p{L}+"#)
    static let salutationPattern = try! NSRegularExpression(
        pattern: #"(?i)^\s*(sehr\s+geehrte|guten\s+tag|hallo\b|liebe[rs]?\b|dear\b)"#)
    static let infoPattern = try! NSRegularExpression(pattern: #"(?i)\b(betreff|betr\.|ihr\s+zeichen|unser\s+zeichen|ihre\s+nachricht|kunden-?\s?(nummer|nr)|rechnungs-?\s?(nummer|nr)|vertrags-?\s?(nummer|nr)|versicherungs-?\s?(nummer|nr|schein)|mitglieds-?\s?(nummer|nr)|aktenzeichen|steuernummer)"#)
    static let closingPattern = try! NSRegularExpression(
        pattern: #"(?i)(mit\s+freundlichen?\s+gr(ü|u|ue)(ß|ss)|freundliche\s+gr(ü|u|ue)(ß|ss)e|viele\s+gr(ü|u|ue)(ß|ss)e|beste\s+gr(ü|u|ue)(ß|ss)e|hochachtungsvoll|kind\s+regards|best\s+regards|sincerely)"#)

    /// Punkte für Merkmale einer ersten Briefseite: Anschriftfeld 2, Anrede 2, Betreff/Zeichen 1, Datum im Kopf 1.
    static func firstPageScore(_ page: Page) -> (Int, String) {
        var score = 0
        var reasons: [String] = []
        // Anschriftfeld: links, unterhalb des Briefkopfs (DIN 5008 ca. 45–90 mm von oben)
        if page.lines.contains(where: { $0.box.minX < 0.4 && (0.55...0.92).contains($0.box.midY)
            && postalPattern.firstMatch(in: $0.text) != nil }) {
            score += 2
            reasons.append("Anschrift")
        }
        if page.lines.contains(where: { $0.box.midY > 0.3 && salutationPattern.firstMatch(in: $0.text) != nil }) {
            score += 2
            reasons.append("Anrede")
        }
        let upper = page.lines.filter { $0.box.midY > 0.45 }
        if upper.contains(where: { infoPattern.firstMatch(in: $0.text) != nil }) {
            score += 1
            reasons.append("Betreff/Zeichen")
        }
        if upper.contains(where: { !DateExtractor.candidates(in: $0.text).isEmpty }) {
            score += 1
            reasons.append("Datum")
        }
        return (score, reasons.joined(separator: ", "))
    }

    /// Wörter (ab 3 Zeichen, ohne reine Zahlen) aus dem oberen und unteren Seitenrand.
    static func edgeTokens(_ page: Page) -> Set<String> {
        var tokens: Set<String> = []
        for line in page.lines where line.box.midY > 0.9 || line.box.midY < 0.12 {
            for word in line.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count >= 3 {
                if word.allSatisfy(\.isNumber) { continue }
                tokens.insert(String(word))
            }
        }
        return tokens
    }
}

private extension NSRegularExpression {
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
