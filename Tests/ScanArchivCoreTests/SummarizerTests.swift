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

struct ModelTextCleaningTests {
    static let letter = """
        #!#METASTART#!#MANDANT#!#GWHS#!#MAILING#!#ZBS210#!#SNR#!#1597105#!#VSA#!#BR#!#PLZ#!#40699#!#METAEND#!#
        Grünwelt Wärmestrom GmbH • Postfach 90 01 13 • 39133 Magdeburg
        Bestellnummer 72138937
        11.12.2025
        Ihre Vertragsbestätigung - Willkommen bei Grünwelt!
        IBAN DE17XXXXXXXXXXXXXX3152
        E-Mail kundenservice@gruenweltenergie.de
        ||||| |||| ||| |||||| ||||
        """

    @Test func removesMachineLinesOnly() {
        let cleaned = Summarizer.cleanedForModel(Self.letter)
        #expect(!cleaned.contains("METASTART"))
        #expect(!cleaned.contains("|||"))
        for kept in ["Grünwelt Wärmestrom GmbH", "Bestellnummer 72138937", "11.12.2025", "Ihre Vertragsbestätigung",
                     "IBAN DE17", "kundenservice@gruenweltenergie.de"] {
            #expect(cleaned.contains(kept), "\(kept) fehlt")
        }
    }

    @Test func strictKeepsLanguageLines() {
        let strict = Summarizer.cleanedForModel("Ihre Vertragsbestätigung\n0800 5555 772 / 774 - 12 %\nMo.-Fr. 7-19 Uhr", strict: true)
        #expect(strict.contains("Ihre Vertragsbestätigung"))
        #expect(!strict.contains("0800 5555 772"))
    }

    /// Mit Steuerzeile lehnt Apple Intelligence sonst mit „unsupported language or locale“ ab.
    @Test(.enabled(if: Summarizer.isAvailable, "Apple Intelligence nicht verfügbar"))
    func suggestionWorksDespiteControlLine() async throws {
        let suggestion = try await Summarizer.suggest(for: Self.letter + "\nGuten Tag, wir freuen uns, dass Sie sich für einen günstigen Stromtarif von Grünwelt entschieden haben. Lieferbeginn 07.01.2026.")
        #expect(!suggestion.title.isEmpty)
    }
}
