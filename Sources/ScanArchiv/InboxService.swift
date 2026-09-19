import Foundation
import Observation
import os
import ScanArchivCore

/// Überwacht den Eingangsordner und verarbeitet neue Dateien nacheinander vollautomatisch.
///
/// Gezogene Dateien werden in den Eingangsordner kopiert und laufen dann denselben Weg.
/// Erfolgreich archivierte Dateien wandern in den Papierkorb, nicht verarbeitbare nach `Fehler/`.
@Observable
@MainActor
final class InboxService {
    struct Item: Identifiable {
        enum State {
            case waiting
            case processing(String)
            case done(ImportResult)
            case failed(String)
        }

        let id = UUID()
        let fileName: String
        /// Ort der Datei im Eingang (bzw. in `Fehler/` nach einem Fehler)
        var url: URL
        let added: Date
        var state: State

        var isPending: Bool {
            switch state {
            case .waiting, .processing: return true
            default: return false
            }
        }
    }

    private(set) var items: [Item] = []
    /// Dateien, die gerade in den Eingang kopiert werden (noch nicht stabil)
    private(set) var arriving: [String] = []
    private(set) var isPaused = false
    private(set) var folder: URL?
    private(set) var error: String?

    var waitingCount: Int { items.filter { if case .waiting = $0.state { return true }; return false }.count }
    var processingCount: Int { items.filter { if case .processing = $0.state { return true }; return false }.count }
    var doneCount: Int { items.filter { if case .done = $0.state { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }

    static let errorFolderName = "Fehler"
    /// Dateien, die gerade noch heruntergeladen/geschrieben werden
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp"]
    /// So lange müssen Größe und Änderungsdatum unverändert sein, bevor eine Datei übernommen wird.
    private static let stableInterval: TimeInterval = 2

    private let model: AppModel
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fallbackTimer: Timer?
    @ObservationIgnored private var recheckScheduled = false
    /// Beobachtete, noch nicht stabile Dateien: Pfad → (Größe, Änderungsdatum, seit wann unverändert)
    @ObservationIgnored private var observed: [String: (size: Int, modified: Date, since: Date)] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// bereits archiviert, ließ sich aber nicht aus dem Eingang entfernen
    @ObservationIgnored private var ignored: Set<String> = []
    private static let log = Logger(subsystem: "de.local.scanarchiv", category: "inbox")

    init(model: AppModel) {
        self.model = model
    }

    var errorFolder: URL? { folder?.appendingPathComponent(Self.errorFolderName, isDirectory: true) }

    // MARK: Überwachung

    /// (Neu) starten mit dem Ordner aus den Einstellungen; liest vorhandene Dateien sofort ein.
    func start() {
        stop()
        let path = UserDefaults.standard.string(forKey: SettingsKey.inboxPath) ?? SettingsKey.defaultInboxPath
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(Self.errorFolderName),
                                                    withIntermediateDirectories: true)
        } catch {
            self.error = "Eingangsordner \(path) kann nicht angelegt werden: \(error.localizedDescription)"
            return
        }
        self.folder = folder
        error = nil

        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scanFolder() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        // Rückfall, falls ein Ereignis verloren geht (z. B. Netzlaufwerk)
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanFolder() }
        }
        Self.log.info("Überwache \(folder.path, privacy: .public)")
        scanFolder()
    }

    func stop() {
        source?.cancel()
        source = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        observed = [:]
        arriving = []
        // wartende Einträge gehören zum alten Ordner
        items.removeAll { if case .waiting = $0.state { return true }; return false }
    }

    /// Liest den Eingangsordner und nimmt stabile, noch unbekannte Dateien in die Warteschlange.
    func scanFolder() {
        guard let folder else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let known = Set(items.filter(\.isPending).map(\.url.path)).union(ignored)
        let now = Date()
        var stillObserved: [String: (size: Int, modified: Date, since: Date)] = [:]
        var ready: [URL] = []

        for url in files where !known.contains(url.path) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  !Self.partialExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate ?? .distantPast
            if let previous = observed[url.path], previous.size == size, previous.modified == modified {
                if now.timeIntervalSince(previous.since) >= Self.stableInterval, size > 0 {
                    ready.append(url)
                } else {
                    stillObserved[url.path] = previous
                }
            } else {
                stillObserved[url.path] = (size, modified, now)
            }
        }
        observed = stillObserved
        arriving = stillObserved.keys.map { ($0 as NSString).lastPathComponent }.sorted()

        for url in ready.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            items.append(Item(fileName: url.lastPathComponent, url: url, added: now, state: .waiting))
            Self.log.info("In Warteschlange: \(url.lastPathComponent, privacy: .public)")
        }
        if !observed.isEmpty { scheduleRecheck() }
        startWorkerIfNeeded()
    }

    /// Erneut prüfen, solange Dateien noch nicht stabil sind (Kopiervorgang läuft evtl. noch).
    private func scheduleRecheck() {
        guard !recheckScheduled else { return }
        recheckScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            recheckScheduled = false
            scanFolder()
        }
    }

    // MARK: Hinzufügen

    /// Kopiert gezogene/ausgewählte Dateien in den Eingangsordner (Originale bleiben erhalten).
    func add(files: [URL]) {
        guard let folder else { return }
        for url in files {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            do {
                try FileManager.default.copyItem(at: url, to: Self.uniqueURL(for: url.lastPathComponent, in: folder))
            } catch {
                items.append(Item(fileName: url.lastPathComponent, url: url, added: Date(),
                                  state: .failed("Kopieren fehlgeschlagen: \(error.localizedDescription)")))
            }
        }
        scanFolder()
    }

    /// „Erneut versuchen“: Datei aus `Fehler/` zurück in den Eingang legen.
    func retry(_ item: Item) {
        guard let folder, case .failed = item.state else { return }
        items.removeAll { $0.id == item.id }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return }
        try? FileManager.default.moveItem(at: item.url, to: Self.uniqueURL(for: item.fileName, in: folder))
        scanFolder()
    }

    func clearFinished() {
        items.removeAll { !$0.isPending }
    }

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        startWorkerIfNeeded()
    }

    static func uniqueURL(for fileName: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(fileName)
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Verarbeitung

    private func startWorkerIfNeeded() {
        guard worker == nil, !isPaused, items.contains(where: { if case .waiting = $0.state { return true }; return false }) else { return }
        worker = Task { await runWorker() }
    }

    /// Arbeitet die Warteschlange strikt nacheinander ab.
    private func runWorker() async {
        defer { worker = nil }
        while !isPaused, let i = items.firstIndex(where: { if case .waiting = $0.state { return true }; return false }) {
            guard let archive = model.archive, let index = model.index, let issueStore = model.issueStore else {
                error = model.error ?? "Kein Archiv geöffnet – der Eingang wartet."
                return
            }
            let id = items[i].id
            let url = items[i].url
            items[i].state = .processing("Wird gelesen …")
            let quality = UserDefaults.standard.double(forKey: SettingsKey.jpegQuality)

            do {
                let result = try await ImportProcessor.process(
                    file: url, archive: archive, index: index, issueStore: issueStore, jpegQuality: quality
                ) { [weak self] step in
                    Task { @MainActor in self?.update(id) { if case .processing = $0.state { $0.state = .processing(step) } } }
                }
                removeFromInbox(url)
                update(id) { $0.state = .done(result) }
                model.didSave()
                Self.log.info("Archiviert: \(url.lastPathComponent, privacy: .public) → \(result.url.lastPathComponent, privacy: .public)")
            } catch {
                var target = url
                if let errorFolder, FileManager.default.fileExists(atPath: url.path) {
                    let destination = Self.uniqueURL(for: url.lastPathComponent, in: errorFolder)
                    if (try? FileManager.default.moveItem(at: url, to: destination)) != nil { target = destination }
                }
                update(id) {
                    $0.url = target
                    $0.state = .failed(error.localizedDescription)
                }
                Self.log.error("Fehler bei \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Archivierte Datei aus dem Eingang entfernen (Papierkorb). Klappt das nicht, wird sie nach
    /// `Erledigt/` verschoben bzw. ignoriert – sonst würde sie beim nächsten Durchlauf doppelt archiviert.
    private func removeFromInbox(_ url: URL) {
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        if let folder {
            let done = folder.appendingPathComponent("Erledigt", isDirectory: true)
            try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: url, to: Self.uniqueURL(for: url.lastPathComponent, in: done))) != nil { return }
        }
        ignored.insert(url.path)
        Self.log.error("\(url.lastPathComponent, privacy: .public) konnte nicht aus dem Eingang entfernt werden")
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }
}
