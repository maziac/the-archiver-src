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

/// Dauerhafte Ablage der Probleme je Dokumentnummer in `.scanarchiv-issues.json` im Archivordner.
/// (Der Suchindex ist nur ein Cache und wird daraus befüllt.)
public final class IssueStore: @unchecked Sendable {
    public static let fileName = ".scanarchiv-issues.json"
    private let url: URL
    private let lock = NSLock()
    private var entries: [Int: [DocumentIssue]]

    public init(folder: URL) {
        url = folder.appendingPathComponent(IssueStore.fileName)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [DocumentIssue]].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Int(key).map { ($0, value) } })
        } else {
            entries = [:]
        }
    }

    public func issues(for number: Int) -> [DocumentIssue] {
        lock.lock(); defer { lock.unlock() }
        return entries[number] ?? []
    }

    public var all: [Int: [DocumentIssue]] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Setzt die Probleme eines Dokuments (leer = keine Probleme).
    public func set(_ issues: [DocumentIssue], for number: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard number > 0 else { return }
        entries[number] = issues.isEmpty ? nil : issues
        try persist()
    }

    /// Entfernt die Probleme, auf die `shouldRemove` zutrifft; liefert die verbleibenden.
    @discardableResult
    public func remove(for number: Int, where shouldRemove: (DocumentIssue) -> Bool) throws -> [DocumentIssue] {
        lock.lock(); defer { lock.unlock() }
        let remaining = (entries[number] ?? []).filter { !shouldRemove($0) }
        entries[number] = remaining.isEmpty ? nil : remaining
        try persist()
        return remaining
    }

    private func persist() throws {
        let encoded = Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(encoded).write(to: url, options: .atomic)
    }
}
