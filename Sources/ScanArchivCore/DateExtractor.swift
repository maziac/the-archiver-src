import Foundation

/// Findet Datumsangaben in (deutschem) OCR-Text.
public enum DateExtractor {
    private static let months: [String: Int] = [
        "januar": 1, "jan": 1, "jänner": 1, "jän": 1,
        "februar": 2, "feb": 2, "febr": 2,
        "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
        "april": 4, "apr": 4,
        "mai": 5,
        "juni": 6, "jun": 6,
        "juli": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "oktober": 10, "okt": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "dez": 12,
    ]

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    private static let numeric = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,2})[./](\d{1,2})[./](\d{4}|\d{2})(?![\d])"#)
    private static let iso = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    private static let named = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\.?\s*(\p{L}{3,9})\.?\s+(\d{4}|\d{2})(?!\d)"#)

    /// Ruft `body` mit den Gruppen (0 = ganzer Treffer) und dem Zeichen-Offset jedes Treffers auf.
    private static func forEachMatch(_ regex: NSRegularExpression, in text: String, _ body: ([String], Int) -> Void) {
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            body(groups, m.range.location)
        }
    }

    /// Alle plausiblen Datumsangaben in der Reihenfolge ihres Vorkommens.
    /// Plausibel: ab 1970 und höchstens 60 Tage in der Zukunft (relativ zu `now`).
    public static func candidates(in text: String, now: Date = Date()) -> [Date] {
        var found: [(offset: Int, date: Date)] = []
        let latest = calendar.date(byAdding: .day, value: 60, to: now) ?? now

        func add(_ day: Int, _ month: Int, _ year: Int, at offset: Int) {
            var y = year
            if y < 100 { y += y > 69 ? 1900 : 2000 }
            guard (1...31).contains(day), (1...12).contains(month), y >= 1970,
                  let date = calendar.date(from: DateComponents(year: y, month: month, day: day, hour: 12)),
                  calendar.component(.day, from: date) == day,  // 31.02. o. ä. verwerfen
                  date <= latest else { return }
            found.append((offset, date))
        }

        // 18.09.2026 · 18.9.26 · 18/09/2026
        forEachMatch(numeric, in: text) { g, offset in
            if let d = Int(g[1]), let mo = Int(g[2]), let y = Int(g[3]) { add(d, mo, y, at: offset) }
        }
        // 2026-09-18
        forEachMatch(iso, in: text) { g, offset in
            if let y = Int(g[1]), let mo = Int(g[2]), let d = Int(g[3]) { add(d, mo, y, at: offset) }
        }
        // 18. September 2026 · 18. Sept. 2026 · 1. März 26
        forEachMatch(named, in: text) { g, offset in
            if let d = Int(g[1]), let mo = months[g[2].lowercased()], let y = Int(g[3]) { add(d, mo, y, at: offset) }
        }
        return found.sorted { $0.offset < $1.offset }.map(\.date)
    }

    /// Erstes plausibles Datum im Text (Brief-/Rechnungsdatum steht meist oben auf Seite 1).
    public static func bestGuess(in text: String, now: Date = Date()) -> Date? {
        candidates(in: text, now: now).first
    }

    /// Übernimmt ein vom Sprachmodell geliefertes Datum (JJJJ-MM-TT) nur,
    /// wenn es tatsächlich im Text vorkommt – schützt vor erfundenen Daten.
    public static func validate(modelDate: String, against text: String, now: Date = Date()) -> Date? {
        guard let m = modelDate.wholeMatch(of: #/\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*/#),
              let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3) else { return nil }
        return candidates(in: text, now: now).first { date in
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return c.year == y && c.month == mo && c.day == d
        }
    }
}
