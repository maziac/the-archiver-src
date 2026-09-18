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

    // MARK: Titel/Beschreibung/Datum bearbeiten

    /// Schreibt die Angaben ins PDF, benennt die Datei um und aktualisiert den Index.
    func updateDocument(path: String, date: Date, title: String, summary: String) async throws {
        guard let archive, let index else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached {
            let newURL = try archive.updateMetadata(url: URL(fileURLWithPath: path), date: date, title: title, summary: summary)
            try index.update(oldPath: path, newURL: newURL, date: date, title: title, summary: summary)
        }.value
        revision += 1
    }

    func suggestion(forPath path: String) async throws -> DocumentSuggestion {
        guard let index else { throw SummarizerError.failed("Kein Archiv geöffnet.") }
        let text = try index.fullText(path: path)
        return try await Summarizer.suggest(for: text)
    }

    // MARK: Titel für vorhandene Dokumente nachtragen

    struct TitleBatch: Equatable {
        var done = 0
        var total = 0
        var failed = 0
    }

    private(set) var titleBatch: TitleBatch?
    /// Ergebnis des letzten Durchlaufs, z. B. "12 Titel erzeugt, 1 fehlgeschlagen"
    private(set) var titleBatchResult: String?
    @ObservationIgnored private var titleBatchTask: Task<Void, Never>?

    var missingTitleCount: Int {
        _ = revision
        return (try? index?.countWithoutTitle()) ?? 0
    }

    func generateMissingTitles() {
        guard titleBatchTask == nil, let index else { return }
        let records = (try? index.recordsWithoutTitle()) ?? []
        guard !records.isEmpty else { return }
        titleBatch = TitleBatch(total: records.count)
        titleBatchResult = nil
        titleBatchTask = Task {
            for record in records {
                if Task.isCancelled { break }
                do {
                    let suggestion = try await Summarizer.suggest(for: record.text)
                    let fileName = URL(fileURLWithPath: record.path).lastPathComponent
                    let date = suggestion.date ?? Archive.parse(fileName: fileName)?.date ?? Date()
                    try await updateDocument(path: record.path, date: date, title: suggestion.title, summary: suggestion.summary)
                } catch {
                    titleBatch?.failed += 1
                }
                titleBatch?.done += 1
            }
            if let batch = titleBatch {
                let ok = batch.done - batch.failed
                titleBatchResult = "\(ok) Titel erzeugt" + (batch.failed > 0 ? ", \(batch.failed) ohne Vorschlag" : "")
            }
            titleBatchTask = nil
            titleBatch = nil
            revision += 1
        }
    }

    func cancelTitleBatch() {
        titleBatchTask?.cancel()
    }
}
