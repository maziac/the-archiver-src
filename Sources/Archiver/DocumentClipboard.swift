import AppKit
import ArchiverCore

/// Legt Archivdokumente als Dateien in die Zwischenablage, damit man sie z. B. im Finder einsetzen kann.
/// Die Kopien (mit oder ohne Nummernstempel) entstehen in einem temporären Ordner; der Finder kopiert
/// sie beim Einsetzen von dort. Ältere Kopien werden beim nächsten Kopieren entfernt.
@MainActor
enum DocumentClipboard {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Archiver-Kopien", isDirectory: true)

    static func copy(_ urls: [URL], withNumber: Bool) throws {
        let copies = try makeCopies(urls, withNumber: withNumber)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(copies as [NSURL])
    }

    /// Kopien im temporären Ordner anlegen (gleiche Dateinamen wie im Archiv).
    static func makeCopies(_ urls: [URL], withNumber: Bool) throws -> [URL] {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var copies: [URL] = []
        for url in urls {
            let copy = target.appendingPathComponent(url.lastPathComponent)
            try DocumentStamp.copyData(url: url, withNumber: withNumber).write(to: copy, options: .atomic)
            copies.append(copy)
        }
        return copies
    }
}
