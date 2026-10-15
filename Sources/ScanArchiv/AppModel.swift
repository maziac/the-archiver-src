import AppKit
import Foundation
import Observation
import PDFKit
import ScanArchivCore

enum SettingsKey {
    static let archivePath = "archivePath"
    static let dpi = "dpi"
    static let rotateBacks = "rotateBacks"
    static let autoOrient = "autoOrient"
    /// Höhe der Seitenminiaturen in Scan-Vorschau und „Seiten bearbeiten“
    static let pageThumbHeight = "pageThumbHeight"
    static let defaultPageThumbHeight = 560.0
    static let pageThumbHeightRange = 200.0...1200.0
    static let singleSource = "singleSource"
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
            autoOrient: true,
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
        let folder = FolderAccess.resolve(key: SettingsKey.archivePath, defaultPath: SettingsKey.defaultArchivePath)
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
            // Einmalig je Archiv: leere Seiten waren früher als „kein Text erkannt“ vermerkt
            let blankKey = "blankPagesV2:" + archive.folder.path  // V2: breiterer Rand (Lochung, Maschinencodes)
            if !UserDefaults.standard.bool(forKey: blankKey) {
                let flagged = ((try? index.search("", onlyIssues: true, limit: 1_000_000)) ?? []).filter { record in
                    record.issues.contains { if case .noText = $0 { true } else { false } }
                }
                for record in flagged {
                    guard let result = try? archive.recheckBlankPages(url: record.url, date: record.date,
                                                                      title: record.title, summary: record.summary) else { continue }
                    try? index.update(oldPath: record.path, newURL: result.url, date: record.date, title: record.title,
                                      summary: record.summary, meta: result.meta)
                }
                UserDefaults.standard.set(true, forKey: blankKey)
            }
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

    // MARK: Kategorien

    /// Startliste und alle im Archiv vergebenen Kategorien – Vorschläge für Eingabe und Apple Intelligence.
    var knownCategories: [String] {
        _ = revision
        return Categories.vocabulary(existing: (try? index?.allCategories()) ?? [])
    }

    /// Benennt eine Kategorie (samt Unterkategorien) in allen Dokumenten um; nil entfernt sie.
    /// Gibt es den neuen Namen schon, werden beide zusammengeführt.
    func renameCategory(_ old: String, to new: String?) async throws {
        guard let archive, let index else { return }
        let new = new.map(Categories.cleanPath)
        try await Task.detached {
            for record in try index.records(inCategory: old) {
                guard let changed = Categories.renamed(record.categories, from: old, to: new) else { continue }
                let result = try archive.updateMetadata(url: record.url, date: record.date, title: record.title,
                                                        summary: record.summary) { $0.categories = changed }
                try index.update(oldPath: record.path, newURL: result.url, date: record.date, title: record.title,
                                 summary: record.summary, meta: result.meta)
            }
        }.value
        revision += 1
    }

    // MARK: Titel/Beschreibung/Datum bearbeiten

    /// Schreibt die Angaben ins PDF (inkl. ScanArchiv-Metadaten), benennt die Datei um und aktualisiert den Index.
    /// - titleSource: neue Herkunft von Titel/Beschreibung (nil = unverändert)
    /// - dateSource: neue Herkunft des Datums (nil = unverändert)
    /// Erledigte Probleme verschwinden: Titel gesetzt → `.noSuggestion`, Datum bestätigt → `.noDate`.
    /// - categories: neue Kategorien (nil = unverändert)
    func updateDocument(path: String, date: Date, title: String, summary: String,
                        titleSource: DocumentMetadata.TitleSource?, dateSource: DocumentMetadata.DateSource?,
                        categories: [String]? = nil) async throws {
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
                if let categories { meta.categories = categories }
                meta.issues.removeAll { issue in
                    switch issue {
                    case .noSuggestion: return !title.isEmpty
                    case .noDate: return dateSource != nil && dateSource != .today
                    case .noText, .pageOrderCorrected, .pageOrderUncertain: return false
                    }
                }
            }
            try index.update(oldPath: path, newURL: result.url, date: date, title: title, summary: summary, meta: result.meta)
        }.value
        revision += 1
    }

    /// „Seiten bearbeiten“: umsortieren/drehen, danach Volltext und Metadaten im Index erneuern.
    func rearrangePages(_ record: DocumentRecord, order: [Int], rotations: [Int]) async throws {
        guard let archive, let index else { return }
        // nichts geändert: bestehende Reihenfolge bestätigen (nur der Reihenfolge-Vermerk verschwindet)
        if order == Array(order.indices), rotations.allSatisfy({ $0 % 360 == 0 }) {
            guard record.issues.contains(where: \.isPageOrder) else { return }
            try await Task.detached {
                let result = try archive.updateMetadata(url: record.url, date: record.date, title: record.title,
                                                        summary: record.summary) { $0.issues.removeAll(where: \.isPageOrder) }
                try index.update(oldPath: record.path, newURL: result.url, date: record.date, title: record.title,
                                 summary: record.summary, meta: result.meta)
            }.value
            revision += 1
            return
        }
        try await Task.detached {
            let result = try archive.rearrange(url: record.url, order: order, rotations: rotations,
                                               title: record.title, summary: record.summary)
            try index.update(oldPath: record.path, newURL: record.url, date: record.date, title: record.title,
                             summary: record.summary, meta: result.meta, text: result.pageTexts.joined(separator: "\n\n"))
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
        return try await Summarizer.suggest(for: await Self.suggestionText(path: path, fallback: fallback),
                                            knownCategories: knownCategories)
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

    // MARK: Titel und Kategorien für vorhandene Dokumente nachtragen

    struct TitleBatch: Equatable {
        enum Kind { case titles, categories }
        var kind: Kind
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

    var missingCategoriesCount: Int {
        _ = revision
        return (try? index?.countWithoutCategories()) ?? 0
    }

    /// Titel, Beschreibung und Datum (und fehlende Kategorien) für Dokumente ohne Titel erzeugen.
    func generateMissingTitles() {
        guard let index else { return }
        runBatch(.titles, records: (try? index.recordsWithoutTitle()) ?? [])
    }

    /// Nur Kategorien für noch nicht kategorisierte Dokumente erzeugen; Titel und Datum bleiben.
    func generateMissingCategories() {
        guard let index else { return }
        runBatch(.categories, records: (try? index.recordsWithoutCategories()) ?? [])
    }

    private func runBatch(_ kind: TitleBatch.Kind, records: [(path: String, text: String)]) {
        guard titleBatchTask == nil, let index, !records.isEmpty else { return }
        titleBatch = TitleBatch(kind: kind, total: records.count)
        titleBatchResult = nil
        titleBatchTask = Task {
            for record in records {
                if Task.isCancelled { break }
                do {
                    let text = await Self.suggestionText(path: record.path, fallback: record.text)
                    let suggestion = try await Summarizer.suggest(for: text, knownCategories: knownCategories)
                    guard let current = try index.record(path: record.path)
                    else { throw SummarizerError.failed("Dokument nicht mehr im Index.") }
                    switch kind {
                    case .titles:
                        let date = suggestion.date ?? current.date
                        try await updateDocument(path: record.path, date: date, title: suggestion.title, summary: suggestion.summary,
                                                 titleSource: .ai, dateSource: suggestion.date != nil ? .ai : nil,
                                                 categories: current.meta?.categories == nil ? suggestion.categories : nil)
                    case .categories:
                        try await updateDocument(path: record.path, date: current.date, title: current.title,
                                                 summary: current.summary, titleSource: nil, dateSource: nil,
                                                 categories: suggestion.categories)
                    }
                } catch {
                    titleBatch?.failed += 1
                }
                titleBatch?.done += 1
            }
            if let batch = titleBatch {
                let ok = batch.done - batch.failed
                let what = batch.kind == .titles ? "Titel erzeugt" : "Dokument(e) kategorisiert"
                titleBatchResult = "\(ok) \(what)" + (batch.failed > 0 ? ", \(batch.failed) ohne Vorschlag" : "")
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
