import Foundation
import Testing
@testable import ScanArchivCore

struct SummarizerTests {
    @Test(.enabled(if: Summarizer.isAvailable, "Apple Intelligence nicht verfügbar"))
    func suggestsTitleSummaryAndDate() async throws {
        let text = """
            Stadtwerke München GmbH · Emmy-Noether-Str. 2 · 80287 München
            Herrn Max Mustermann, Musterstr. 5, 80331 München
            Abrechnungszeitraum 01.08.2025 - 31.07.2026
            München, 18.09.2026
            Stromrechnung Nr. 4711-2026
            Gesamtbetrag 1.234,56 EUR. Bitte überweisen Sie den Betrag bis zum 30.10.2026.
            """
        let suggestion = try await Summarizer.suggest(for: text)
        let words = suggestion.title.split(separator: " ").count
        #expect((1...8).contains(words), "Titel: \(suggestion.title)")
        #expect(!suggestion.summary.isEmpty)
        #expect(suggestion.date.map { Archive.formatDate($0) } == "2026-09-18", "Datum: \(String(describing: suggestion.date))")
        print("Vorschlag:", suggestion.title, "|", suggestion.summary)
    }
}
