import AppKit
import Foundation
import Observation
import ScanArchivCore

enum SettingsKey {
    static let archivePath = "archivePath"
    static let dpi = "dpi"
    static let color = "color"
    static let rotateBacks = "rotateBacks"
    static let jpegQuality = "jpegQuality"

    static var defaultArchivePath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanArchiv").path
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            archivePath: defaultArchivePath,
            dpi: 300,
            color: false,
            rotateBacks: false,
            jpegQuality: 0.7,
        ])
    }
}

/// Archivordner + Suchindex; wird neu aufgebaut, wenn sich der Archivordner ändert.
@Observable
@MainActor
final class AppModel {
    private(set) var archive: Archive?
    private(set) var index: SearchIndex?
    private(set) var error: String?
    /// Wird nach jedem gespeicherten Dokument / Reindex erhöht, damit die Suche neu lädt.
    private(set) var revision = 0

    init() {
        SettingsKey.registerDefaults()
        openArchive()
    }

    var archivePath: String { UserDefaults.standard.string(forKey: SettingsKey.archivePath) ?? SettingsKey.defaultArchivePath }

    func openArchive() {
        let folder = URL(fileURLWithPath: archivePath, isDirectory: true)
        do {
            let archive = try Archive(folder: folder)
            let index = try SearchIndex(url: folder.appendingPathComponent(SearchIndex.fileName))
            self.archive = archive
            self.index = index
            error = nil
            reindex(full: false)
        } catch {
            self.archive = nil
            self.index = nil
            self.error = error.localizedDescription
        }
    }

    func reindex(full: Bool) {
        guard let index, let archive else { return }
        Task.detached(priority: .utility) {
            try? index.sync(folder: archive.folder, full: full)
            await MainActor.run { self.revision += 1 }
        }
    }

    func didSave() { revision += 1 }
}
