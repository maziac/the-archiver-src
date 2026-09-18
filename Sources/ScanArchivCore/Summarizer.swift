import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Vorschlag für Titel, Beschreibung und Dokumentdatum.
public struct DocumentSuggestion: Sendable, Equatable {
    public var title: String
    public var summary: String
    /// nil = kein Datum im Text gefunden
    public var date: Date?

    public init(title: String, summary: String, date: Date?) {
        self.title = title
        self.summary = summary
        self.date = date
    }
}

public enum SummarizerError: LocalizedError {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .failed(message): return message
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct GeneratedSummary {
    @Guide(description: "Aussagekräftiger deutscher Titel mit 3 bis 6 Wörtern: Dokumentart, Absender und ggf. Zeitraum, z. B. 'Stromrechnung Stadtwerke München 2026' oder 'Kündigungsbestätigung Fitnessstudio FitX'")
    var title: String
    @Guide(description: "Ein bis zwei deutsche Sätze: Absender, Art des Dokuments und die wichtigsten Angaben wie Betrag, Frist oder Zeitraum")
    var summary: String
    @Guide(description: "Ausstellungsdatum des Dokuments (Brief- oder Rechnungsdatum, nicht Fälligkeit oder Zeitraum) im Format JJJJ-MM-TT; leer, wenn keines erkennbar ist")
    var documentDate: String
}
#endif

/// Erzeugt Titel und Kurzbeschreibung lokal mit Apple Intelligence (FoundationModels).
public enum Summarizer {
    /// Maximale Textlänge für das Modell (Kontextfenster ca. 4k Tokens).
    static let maxCharacters = 5000

    /// nil = verfügbar, sonst deutscher Hinweis, warum nicht.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence ist nicht aktiviert (Systemeinstellungen → Apple Intelligence & Siri)."
            case .unavailable(.deviceNotEligible):
                return "Dieser Mac unterstützt Apple Intelligence nicht."
            case .unavailable(.modelNotReady):
                return "Das Apple-Intelligence-Modell wird noch geladen. Bitte später erneut versuchen."
            case .unavailable:
                return "Apple Intelligence ist nicht verfügbar."
            }
        }
        #endif
        return "Titelvorschläge benötigen macOS 26 mit Apple Intelligence."
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    /// Vorschlag aus dem OCR-Text. Das Datum wird nur übernommen, wenn es wirklich im Text steht;
    /// sonst gilt das erste plausible Datum im Text.
    public static func suggest(for text: String) async throws -> DocumentSuggestion {
        let fallbackDate = DateExtractor.bestGuess(in: text)
        if let reason = unavailableReason { throw SummarizerError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                Du archivierst gescannte Dokumente (Briefe, Rechnungen, Verträge, Bescheide). \
                Der Text stammt aus einer Texterkennung und kann Fehler enthalten. \
                Antworte immer auf Deutsch und erfinde keine Angaben, die nicht im Text stehen.
                """)
            do {
                let response = try await session.respond(
                    to: "Dokumenttext:\n\(String(text.prefix(maxCharacters)))",
                    generating: GeneratedSummary.self)
                let generated = response.content
                return DocumentSuggestion(
                    title: generated.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'"))),
                    summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    date: DateExtractor.validate(modelDate: generated.documentDate, against: text) ?? fallbackDate)
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation, .refusal:
                    throw SummarizerError.failed("Apple Intelligence hat für dieses Dokument keinen Vorschlag erzeugt.")
                case .exceededContextWindowSize:
                    throw SummarizerError.failed("Der Text ist zu lang für Apple Intelligence.")
                default:
                    throw SummarizerError.failed("Vorschlag fehlgeschlagen: \(error.localizedDescription)")
                }
            }
        }
        #endif
        throw SummarizerError.unavailable(unavailableReason ?? "")
    }
}
