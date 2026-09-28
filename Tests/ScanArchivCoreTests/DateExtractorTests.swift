import Foundation
import Testing
@testable import ScanArchivCore

struct DateExtractorTests {
    let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 18, hour: 12).date!

    func ymd(_ date: Date?) -> String? {
        date.map { Archive.formatDate($0) }
    }

    @Test func numericFormats() {
        let dates = DateExtractor.candidates(in: "am 18.09.2026, 1.2.25 und 03/04/2024", now: now)
        #expect(dates.map(ymd) == ["2026-09-18", "2025-02-01", "2024-04-03"])
    }

    @Test func monthNames() {
        let dates = DateExtractor.candidates(in: "München, 18. September 2026 – Termin 1. März 2026, Stand 5. Sept. 2025, 7. Okt 2025", now: now)
        #expect(dates.map(ymd) == ["2026-09-18", "2026-03-01", "2025-09-05", "2025-10-07"])
    }

    @Test func englishMonthNames() {
        let text = "London, 14 March 2026 – due 1st of May, 2026, sent Mar 3rd 2026, paid August 5, 2025, Oct. 7 2025"
        let dates = DateExtractor.candidates(in: text, now: now)
        #expect(dates.map(ymd) == ["2026-03-14", "2026-05-01", "2026-03-03", "2025-08-05", "2025-10-07"])
    }

    @Test func americanNumericOnlyWhenUnambiguous() {
        // 03/14/2026 geht nur als Monat/Tag; 03/04/2026 bleibt deutsch gelesen (3. April)
        let dates = DateExtractor.candidates(in: "03/14/2026 und 03/04/2026", now: now)
        #expect(dates.map(ymd) == ["2026-03-14", "2026-04-03"])
        #expect(DateExtractor.candidates(in: "14.13.2026", now: now).isEmpty)
    }

    @Test func noFalseEnglishDates() {
        #expect(DateExtractor.candidates(in: "Seite 1 von 2026, Punkte 12 2026, Rechnung Nr 14 2026", now: now).isEmpty)
    }

    @Test func isoFormat() {
        #expect(ymd(DateExtractor.bestGuess(in: "Datum: 2026-09-01", now: now)) == "2026-09-01")
    }

    @Test func rejectsImplausible() {
        // 31.02. gibt es nicht, 1960 zu alt, 2030 zu weit in der Zukunft, 1.234,56 ist ein Betrag
        #expect(DateExtractor.candidates(in: "31.02.2026 01.01.1960 01.01.2030 1.234,56 EUR 12.5", now: now).isEmpty)
    }

    @Test func firstDateWins() {
        let text = "Stadtwerke München\nMünchen, 18.09.2026\nZeitraum 01.08.2025 - 31.07.2026\nzahlbar bis 30.10.2026"
        #expect(ymd(DateExtractor.bestGuess(in: text, now: now)) == "2026-09-18")
    }

    @Test func modelDateMustBeInText() {
        let text = "Rechnung vom 18.09.2026, fällig am 30.10.2026"
        #expect(ymd(DateExtractor.validate(modelDate: "2026-10-30", against: text, now: now)) == "2026-10-30")
        #expect(DateExtractor.validate(modelDate: "2026-01-01", against: text, now: now) == nil)
        #expect(DateExtractor.validate(modelDate: "", against: text, now: now) == nil)
    }
}
