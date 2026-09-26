import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Vorschlag für Titel, Beschreibung, Dokumentdatum und Kategorien.
public struct DocumentSuggestion: Sendable, Equatable {
    public var title: String
    public var summary: String
    /// nil = kein Datum im Text gefunden
    public var date: Date?
    /// Kategorien (bereits an vorhandene angeglichen), z. B. „Absender/DAK“, „Rechnung“
    public var categories: [String]

    public init(title: String, summary: String, date: Date?, categories: [String] = []) {
        self.title = title
        self.summary = summary
        self.date = date
        self.categories = categories
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
    @Guide(description: "Ausstellungsdatum des Dokuments (Brief- oder Rechnungsdatum, nicht Fälligkeit oder Zeitraum) im Format JJJJ-MM-TT; leer, wenn keines erkennbar ist")
    var documentDate: String
    @Guide(description: "Aussagekräftiger deutscher Titel mit 3 bis 6 Wörtern: Dokumentart, Absender und ggf. Zeitraum, z. B. 'Stromrechnung Stadtwerke München 2026' oder 'Kündigungsbestätigung Fitnessstudio FitX'")
    var title: String
    @Guide(description: "Ein bis zwei deutsche Sätze: Absender, Art des Dokuments und die wichtigsten Angaben wie Betrag, Frist oder Zeitraum")
    var summary: String
    @Guide(description: "Kurzer, gebräuchlicher Name des Absenders (Firma, Behörde, Kasse, Person), z. B. 'DAK', 'Deutsche Rentenversicherung', 'Stadtwerke München'; leer, wenn nicht erkennbar")
    var sender: String
    @Guide(description: "Ein bis drei deutsche Kategorien für Dokumentart und Thema, je ein Wort im Singular, z. B. 'Rechnung', 'Krankenkasse'. Aus der Liste der vorhandenen Kategorien, und nur solche, deren Beschreibung eindeutig zutrifft – lieber weniger als eine unsichere. Eine neue Kategorie nur, wenn keine vorhandene passt. Nicht den Absender.", .count(1...3))
    var categories: [String]
}
#endif

/// Erzeugt Titel und Kurzbeschreibung lokal mit Apple Intelligence (FoundationModels).
public enum Summarizer {
    /// Maximale Textlänge für das Modell. Titel, Art und Datum stehen fast immer auf den ersten
    /// Seiten; weniger Text heißt schnellere Antwort.
    static let maxCharacters = 3000

    static let instructions = """
        Du archivierst gescannte Dokumente (Briefe, Rechnungen, Verträge, Bescheide). \
        Der Text stammt aus einer Texterkennung und kann Fehler enthalten. \
        Antworte immer auf Deutsch und erfinde keine Angaben, die nicht im Text stehen.
        """

    #if canImport(FoundationModels)
    /// Vorgewärmte Session für den nächsten Vorschlag (Modell ist dann schon geladen).
    nonisolated(unsafe) private static var warmSession: AnyObject?
    private static let lock = NSLock()

    @available(macOS 26, *)
    private static func takeSession() -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        let session = warmSession as? LanguageModelSession
        warmSession = nil
        return session ?? LanguageModelSession(instructions: instructions)
    }
    #endif

    /// Lädt das Modell vorab, damit der nächste Vorschlag schneller kommt.
    public static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            lock.lock(); defer { lock.unlock() }
            guard warmSession == nil else { return }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            warmSession = session
        }
        #endif
    }

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
    /// - knownCategories: bereits vorhandene Kategorien (inkl. „Absender/…“); das Modell bevorzugt sie,
    ///   und das Ergebnis wird an ihre Schreibweise angeglichen.
    public static func suggest(for text: String, knownCategories: [String] = Categories.defaults) async throws -> DocumentSuggestion {
        let fallbackDate = DateExtractor.bestGuess(in: text)
        if let reason = unavailableReason { throw SummarizerError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                return try await generate(from: cleanedForModel(text), fullText: text, fallbackDate: fallbackDate,
                                          known: knownCategories)
            } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
                // zweiter Versuch nur mit eindeutigen Textzeilen (z. B. Steuer-/Codezeilen im PDF)
                do {
                    return try await generate(from: cleanedForModel(text, strict: true), fullText: text, fallbackDate: fallbackDate,
                                              known: knownCategories)
                } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
                    throw SummarizerError.failed("Apple Intelligence hält die Sprache des Textes für nicht unterstützt.")
                }
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

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func generate(from modelText: String, fullText: String, fallbackDate: Date?,
                                 known: [String]) async throws -> DocumentSuggestion {
        let response = try await takeSession().respond(
            to: prompt(modelText: modelText, known: known),
            generating: GeneratedSummary.self)
        let generated = response.content
        let sender = generated.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentSuggestion(
            title: generated.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'"))),
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            date: DateExtractor.validate(modelDate: generated.documentDate, against: fullText) ?? fallbackDate,
            categories: Categories.verified(
                Categories.normalize(generated.categories, sender: sender.isEmpty ? nil : sender, known: known), text: fullText))
    }
    #endif

    /// Anfrage an das Modell: Dokumenttext, dann vorhandene Kategorien und Absender.
    static func prompt(modelText: String, known: [String]) -> String {
        let senders = Categories.senders(in: known)
        let kinds = known.filter { Categories.expanded([$0]).first != Categories.senderRoot }
        // Dokumenttext zuerst: eine lange Liste davor lenkt das Modell z. B. beim Datum ab
        var prompt = "Dokumenttext:\n\(String(modelText.prefix(maxCharacters)))\n"
        if !kinds.isEmpty {
            prompt += "\nVorhandene Kategorien (nur vergeben, wenn die Beschreibung eindeutig zutrifft):\n"
            for kind in kinds {
                prompt += "- " + kind + (Categories.descriptions[kind].map { ": " + $0 } ?? "") + "\n"
            }
        }
        if !senders.isEmpty { prompt += "\nBekannte Absender: \(senders.prefix(200).joined(separator: ", "))\n" }
        return prompt
    }

    /// Entfernt maschinelle Zeilen, die das Sprachmodell irritieren – z. B. unsichtbare Steuerzeilen von
    /// Druckdienstleistern („#!#METASTART#!#MANDANT#!#…“), Barcode-Inhalte oder Zeichensalat.
    /// Der Text im Archiv und im Suchindex bleibt davon unberührt.
    /// - strict: nur Zeilen behalten, die überwiegend aus Buchstaben und Leerzeichen bestehen
    static func cleanedForModel(_ text: String, strict: Bool = false) -> String {
        text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            let scalars = trimmed.unicodeScalars
            let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
            let spaces = scalars.filter { CharacterSet.whitespaces.contains($0) }.count
            let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            let symbols = scalars.count - letters - spaces - digits
            // sehr lange Zeichenkette ohne Leerzeichen (keine normale Sprache)
            if trimmed.split(separator: " ").contains(where: { $0.count > 40 }) { return false }
            // überwiegend Sonderzeichen
            if scalars.count >= 8, Double(symbols) / Double(scalars.count) > 0.3 { return false }
            // Wiederholte Trennmuster wie „#!#“, „|||“, „~~~“
            if trimmed.contains("#!#") || trimmed.contains("|||") { return false }
            if strict {
                return scalars.count < 4 || Double(letters + spaces) / Double(scalars.count) >= 0.6
            }
            return true
        }.joined(separator: "\n")
    }
}
