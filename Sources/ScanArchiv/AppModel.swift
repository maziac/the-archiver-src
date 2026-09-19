import AppKit
import Foundation
import Observation
import PDFKit
import ScanArchivCore

enum SettingsKey {
    static let archivePath = "archivePath"
    static let dpi = "dpi"
    static let rotateBacks = "rotateBacks"
    static let inboxPath = "inboxPath"
    // Kompression (Werte: rawValue von SizePreset / ColorMode)
    static let scanPreset = "scanPreset"
    static let scanColorMode = "scanColorMode"
    static let pdfPreset = "pdfPreset"
    static let imagePreset = "imagePreset"
    static let importColorMode = "importColorMode"

    static var defaultArchivePath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanArchiv").path
    }

    static var defaultInboxPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanArchiv-Eingang").path
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            archivePath: defaultArchivePath,
            inboxPath: defaultInboxPath,
            dpi: 300,
            rotateBacks: false,
            scanPreset: SizePreset.kb150.rawValue,
            scanColorMode: ColorMode.gray.rawValue,
            pdfPreset: SizePreset.original.rawValue,
            imagePreset: SizePreset.kb150.rawValue,
            importColorMode: ColorMode.original.rawValue,
        ])
    }

    static func preset(_ key: String) -> SizePreset {
        SizePreset(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .original
    }

    static func colorMode(_ key: String) -> ColorMode {
        ColorMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .original
    }

    static var importOptions: ImportOptions {
        ImportOptions(pdfPreset: preset(pdfPreset), imagePreset: preset(imagePreset), colorMode: colorMode(importColorMode))
    }
}

enum AppTab: Hashable {
    case scan, inbox, archive
}

/// Archivordner + Suchindex; wird neu aufgebaut, wenn sich der Archivordner ändert.
@Observable
@MainActor
final class AppModel {
    private(set) var archive: Archive?
    private(set) var index: SearchIndex?
    /// Tags (gespeicherte Suchen) des Archivs
    private(set) var tagStore: TagStore?
    private(set) var tags: [Tag] = []
    var selectedTab: AppTab = .scan
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
            let tagStore = TagStore(folder: folder)
            self.tagStore = tagStore
            tags = tagStore.all
            error = nil
            reindex(full: false)
        } catch {
            self.archive = nil
            self.index = nil
            tagStore = nil
            tags = []
            self.error = error.localizedDescription
        }
    }

    func reindex(full: Bool) {
        guard let index, let archive else { return }
        Task.detached(priority: .utility) {
            // Altbestand ohne Metadaten wird dabei einmalig ergänzt (inkl. alter Problem-Vermerke)
            let legacy = LegacyIssues.load(folder: archive.folder)
            // Einmalig: früher falsch beschrifteten Altbestand korrigieren (Erstellversion, Textherkunft)
            var repaired = false
            let repairKey = "legacyRepairV1"
            if !UserDefaults.standard.bool(forKey: repairKey) {
                let files = (try? FileManager.default.contentsOfDirectory(at: archive.folder, includingPropertiesForKeys: nil)) ?? []
                for url in files where url.pathExtension.lowercased() == "pdf" {
                    if (try? archive.repairLegacyMetadata(url: url)) == true { repaired = true }
                }
                UserDefaults.standard.set(true, forKey: repairKey)
            }
            try? index.sync(folder: archive.folder, full: full || repaired) { url in
                let number = Archive.parse(fileName: url.lastPathComponent)?.number ?? 0
                try? archive.migrateLegacy(url: url, issues: legacy[number] ?? [])
            }
            if !legacy.isEmpty { LegacyIssues.remove(folder: archive.folder) }
            await MainActor.run { self.revision += 1 }
        }
    }

    func didSave() { revision += 1 }

    // MARK: Tags

    func saveTag(_ tag: Tag) throws {
        guard let tagStore else { return }
        if tags.contains(where: { $0.id == tag.id }) { try tagStore.update(tag) } else { try tagStore.add(tag) }
        tags = tagStore.all
    }

    func removeTag(_ tag: Tag) throws {
        guard let tagStore else { return }
        try tagStore.remove(id: tag.id)
        tags = tagStore.all
    }

    // MARK: Titel/Beschreibung/Datum bearbeiten

    /// Schreibt die Angaben ins PDF (inkl. ScanArchiv-Metadaten), benennt die Datei um und aktualisiert den Index.
    /// - titleSource: neue Herkunft von Titel/Beschreibung (nil = unverändert)
    /// - dateSource: neue Herkunft des Datums (nil = unverändert)
    /// Erledigte Probleme verschwinden: Titel gesetzt → `.noSuggestion`, Datum bestätigt → `.noDate`.
    func updateDocument(path: String, date: Date, title: String, summary: String,
                        titleSource: DocumentMetadata.TitleSource?, dateSource: DocumentMetadata.DateSource?) async throws {
        guard let archive, let index else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached {
            let result = try archive.updateMetadata(url: URL(fileURLWithPath: path), date: date, title: title, summary: summary) { meta in
                if let titleSource {
                    meta.titleSource = title.isEmpty ? .none : titleSource
                    meta.titleUpdated = Date()
                }
                if let dateSource { meta.dateSource = dateSource }
                meta.issues.removeAll { issue in
                    switch issue {
                    case .noSuggestion: return !title.isEmpty
                    case .noDate: return dateSource != nil && dateSource != .today
                    case .noText: return false
                    }
                }
            }
            try index.update(oldPath: path, newURL: result.url, date: date, title: title, summary: summary, meta: result.meta)
        }.value
        revision += 1
    }

    /// „Als geprüft markieren“: alle Probleme der Dokumente entfernen (im PDF und im Index).
    func markReviewed(_ records: [DocumentRecord]) async throws {
        guard let archive, let index else { return }
        try await Task.detached {
            for record in records where record.number > 0 {
                let result = try archive.updateMetadata(url: record.url, date: record.date, title: record.title,
                                                        summary: record.summary) { $0.issues = [] }
                try index.update(oldPath: record.path, newURL: result.url, date: record.date, title: record.title,
                                 summary: record.summary, meta: result.meta)
            }
        }.value
        revision += 1
    }

    var issueCount: Int {
        _ = revision
        return (try? index?.countWithIssues()) ?? 0
    }

    /// Legt Dokumente in den Papierkorb (wiederherstellbar) und nimmt sie aus dem Index.
    /// Ihre Nummern werden nicht erneut vergeben (Zähler in counter.json).
    func deleteDocuments(paths: [String]) throws {
        guard let index else { return }
        defer { revision += 1 }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            try index.remove(path: path)
        }
    }

    func suggestion(forPath path: String) async throws -> DocumentSuggestion {
        guard let index else { throw SummarizerError.failed("Kein Archiv geöffnet.") }
        let fallback = try index.fullText(path: path)
        return try await Summarizer.suggest(for: await Self.suggestionText(path: path, fallback: fallback))
    }

    /// Text der ersten Seiten (wie beim Scannen) – schneller und für Titel/Datum ausreichend.
    nonisolated static func suggestionText(path: String, fallback: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)), pdf.pageCount > 0 else { return fallback }
            let text = (0..<min(pdf.pageCount, ScanSession.suggestionPageCount))
                .compactMap { pdf.page(at: $0)?.string }
                .joined(separator: "\n\n")
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
        }.value
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
                    let text = await Self.suggestionText(path: record.path, fallback: record.text)
                    let suggestion = try await Summarizer.suggest(for: text)
                    let fileName = URL(fileURLWithPath: record.path).lastPathComponent
                    let date = suggestion.date ?? Archive.parse(fileName: fileName)?.date ?? Date()
                    try await updateDocument(path: record.path, date: date, title: suggestion.title, summary: suggestion.summary,
                                             titleSource: .ai, dateSource: suggestion.date != nil ? .ai : nil)
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
