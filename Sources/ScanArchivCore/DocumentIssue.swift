import Foundation

/// Ein Problem bei der Verarbeitung: Das Dokument wurde archiviert, sollte aber geprüft werden.
public enum DocumentIssue: Codable, Hashable, Sendable {
    /// Auf diesen Bild-Seiten (ab 1) hat die Texterkennung keinen Text gefunden.
    case noText(pages: [Int])
    /// Titel/Beschreibung fehlen (Grund, z. B. Apple Intelligence nicht verfügbar).
    case noSuggestion(String)
    /// Kein Datum im Text gefunden – es gilt das Datum der Verarbeitung.
    case noDate

    public var message: String {
        switch self {
        case let .noText(pages):
            let list = pages.map(String.init).joined(separator: ", ")
            return pages.count == 1 ? "Seite \(list): kein Text erkannt" : "Seiten \(list): kein Text erkannt"
        case let .noSuggestion(reason):
            return reason.isEmpty ? "kein Titel/keine Beschreibung" : "kein Titel/keine Beschreibung – \(reason)"
        case .noDate:
            return "kein Datum gefunden (Tagesdatum verwendet)"
        }
    }

    /// Mindestanzahl Buchstaben/Ziffern, ab der eine Seite als „mit Text“ gilt.
    public static let minTextCharacters = 10

    public static func hasText(_ text: String) -> Bool {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= minTextCharacters
    }

    static func encode(_ issues: [DocumentIssue]) -> String {
        guard !issues.isEmpty, let data = try? JSONEncoder().encode(issues) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [DocumentIssue] {
        guard !text.isEmpty else { return [] }
        return (try? JSONDecoder().decode([DocumentIssue].self, from: Data(text.utf8))) ?? []
    }
}

/// Liest die Problem-Vermerke aus der früheren Zusatzdatei `.scanarchiv-issues.json` (vor Version 1.0).
/// Sie werden bei der Migration ins PDF übernommen; danach wird die Datei gelöscht.
public enum LegacyIssues {
    public static let fileName = ".scanarchiv-issues.json"

    public static func load(folder: URL) -> [Int: [DocumentIssue]] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let decoded = try? JSONDecoder().decode([String: [DocumentIssue]].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    public static func remove(folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
    }
}
