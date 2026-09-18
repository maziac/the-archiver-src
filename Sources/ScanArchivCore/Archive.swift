import Foundation

public enum ArchiveError: LocalizedError {
    case cannotCreateFolder(URL, Error)

    public var errorDescription: String? {
        switch self {
        case let .cannotCreateFolder(url, error):
            return "Archivordner \(url.path) kann nicht angelegt werden: \(error.localizedDescription)"
        }
    }
}

/// Archivordner mit fortlaufender, eindeutiger Dokumentnummer.
///
/// Dateiname: `JJJJ-MM-TT_NNNNNN.pdf`. Der Zählerstand liegt in `counter.json` im Archivordner;
/// maßgeblich ist immer das Maximum aus Zähler und höchster Nummer vorhandener Dateien,
/// damit keine Nummer doppelt vergeben wird.
public final class Archive: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var counterURL: URL { folder.appendingPathComponent("counter.json") }

    public init(folder: URL) throws {
        self.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.cannotCreateFolder(folder, error)
        }
    }

    // MARK: Dateinamen

    public static func formatNumber(_ number: Int) -> String {
        String(format: "%06d", number)
    }

    public static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func fileName(date: Date, number: Int) -> String {
        "\(formatDate(date))_\(formatNumber(number)).pdf"
    }

    /// Liest Datum und Nummer aus einem Archiv-Dateinamen, sonst nil.
    public static func parse(fileName: String) -> (date: Date, number: Int)? {
        guard let match = fileName.wholeMatch(of: #/(\d{4}-\d{2}-\d{2})_(\d{6,})\.pdf/#),
              let number = Int(match.2) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: String(match.1)) else { return nil }
        return (date, number)
    }

    // MARK: Nummernvergabe

    public func highestExistingNumber() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { Archive.parse(fileName: $0)?.number }.max() ?? 0
    }

    private struct Counter: Codable { var lastNumber: Int }

    private func storedCounter() -> Int {
        guard let data = try? Data(contentsOf: counterURL),
              let counter = try? JSONDecoder().decode(Counter.self, from: data) else { return 0 }
        return counter.lastNumber
    }

    /// Die Nummer, die das nächste gespeicherte Dokument bekommt (ohne sie zu reservieren).
    public func peekNextNumber() -> Int {
        lock.lock(); defer { lock.unlock() }
        return max(storedCounter(), highestExistingNumber()) + 1
    }

    /// Vergibt die nächste Nummer, schreibt das PDF und aktualisiert den Zähler.
    /// `makePDF` erhält die vergebene Nummer, damit sie ins Dokument gestempelt werden kann.
    public func save(date: Date, makePDF: (Int) throws -> Data) throws -> (number: Int, url: URL) {
        lock.lock(); defer { lock.unlock() }
        var number = max(storedCounter(), highestExistingNumber()) + 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(Archive.fileName(date: date, number: number)).path) {
            number += 1
        }
        let url = folder.appendingPathComponent(Archive.fileName(date: date, number: number))
        let data = try makePDF(number)
        try data.write(to: url, options: .withoutOverwriting)
        let counter = try JSONEncoder().encode(Counter(lastNumber: number))
        try counter.write(to: counterURL, options: .atomic)
        return (number, url)
    }
}
