import Foundation

/// Dauerhafter Zugriff auf vom Benutzer gewählte Ordner in der App Sandbox (Security-Scoped Bookmarks).
/// Neben dem Pfad (`SettingsKey.archivePath`/`inboxPath`) liegt ein Bookmark unter `<Schlüssel>Bookmark`.
/// Es gilt nur, solange es auf denselben Pfad zeigt – ein per Startargument (`-archivePath …`)
/// überschriebener Pfad wird also direkt verwendet.
@MainActor
enum FolderAccess {
    /// Ordner, deren Zugriff gerade geöffnet ist (je Einstellungsschlüssel)
    private static var accessed: [String: URL] = [:]

    private static func bookmarkKey(_ key: String) -> String { key + "Bookmark" }

    /// Nach der Wahl im NSOpenPanel: Pfad und Bookmark speichern.
    static func store(_ url: URL, forKey key: String) {
        UserDefaults.standard.set(url.path, forKey: key)
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey(key))
        } else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey(key))
        }
    }

    /// Ordner zum Schlüssel; öffnet den Zugriff über das Bookmark (und schließt den vorherigen).
    static func resolve(key: String, defaultPath: String) -> URL {
        let path = UserDefaults.standard.string(forKey: key) ?? defaultPath
        if let previous = accessed.removeValue(forKey: key) { previous.stopAccessingSecurityScopedResource() }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey(key)) else {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
        else {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if url.startAccessingSecurityScopedResource() { accessed[key] = url }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey(key))
        }
        return url
    }
}
