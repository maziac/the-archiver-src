import ScanArchivCore
import SwiftUI
import UniformTypeIdentifiers

/// Tab „Eingang“: Dateien ablegen, Warteschlange und Ergebnisse der automatischen Verarbeitung.
struct InboxView: View {
    @Environment(InboxService.self) private var inbox
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var selection = Set<InboxService.Item.ID>()

    var body: some View {
        VStack(spacing: 0) {
            dropArea
                .padding(16)
            Divider()
            header
            Divider()
            queueList
            Divider()
            footer
        }
        .sheet(isPresented: Binding(get: { !inbox.pendingFolders.isEmpty }, set: { if !$0 { inbox.pendingFolders = [] } })) {
            FolderImportSheet(folders: inbox.pendingFolders) { files in inbox.add(files: files) }
        }
        .sheet(isPresented: Binding(get: { !inbox.pendingImages.isEmpty }, set: { if !$0 { inbox.pendingImages = [] } })) {
            let images = inbox.pendingImages
            MultipleImagesSheet(images: images,
                                onCombine: { inbox.addCombined(images: images) },
                                onSeparate: { inbox.add(files: images) })
        }
    }

    // MARK: Ablagefläche

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text("PDFs, Bilder oder Ordner hierher ziehen")
                .font(.title3.weight(.semibold))
            Text("Jede Datei wird automatisch zu einem eigenen Dokument: Texterkennung, Titel, Beschreibung, Datum und Nummer. Bei mehreren Bildern wird gefragt, ob sie ein gemeinsames Dokument ergeben. Die Originale bleiben erhalten.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Dateien oder Ordner auswählen …") { chooseFiles() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: dropTargeted ? 3 : 1.5, dash: [8]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            inbox.accept(urls)  // Dateien sofort, Ordner über den Dialog
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Dateien in den Eingang legen"
        panel.prompt = "Übernehmen"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf] + ImportProcessor.imageTypes
        if panel.runModal() == .OK { inbox.accept(panel.urls) }
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(spacing: 12) {
            Text(statusLine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let error = inbox.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if inbox.isPaused {
                Button("Fortsetzen", systemImage: "play.fill") { inbox.resume() }
            } else {
                Button("Pause", systemImage: "pause.fill") { inbox.pause() }
                    .help("Die laufende Datei wird noch fertig verarbeitet.")
            }
            Button("Erledigte ausblenden") { inbox.clearFinished() }
                .disabled(inbox.doneCount + inbox.failedCount + inbox.duplicateCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        var parts: [String] = []
        if let copying = inbox.copying { parts.append("kopiere \(copying.done) / \(copying.total)") }
        parts += ["\(inbox.waitingCount) wartend", "\(inbox.processingCount) in Arbeit", "\(inbox.doneCount) fertig"]
        if inbox.duplicateCount > 0 { parts.append("\(inbox.duplicateCount) Duplikat(e)") }
        if inbox.failedCount > 0 { parts.append("\(inbox.failedCount) Fehler") }
        if inbox.isPaused { parts.append("pausiert") }
        return parts.joined(separator: " · ")
    }

    // MARK: Warteschlange

    private var queueList: some View {
        List(selection: $selection) {
            ForEach(inbox.arriving, id: \.self) { name in
                HStack {
                    ProgressView().controlSize(.small).frame(width: 20)
                    Text(name).lineLimit(1)
                    Spacer()
                    Text("wird übertragen …").foregroundStyle(.secondary)
                }
            }
            ForEach(inbox.items.reversed()) { item in
                InboxRow(item: item)
                    .tag(item.id)
            }
        }
        .contextMenu(forSelectionType: InboxService.Item.ID.self) { ids in
            let selected = inbox.items.filter { ids.contains($0.id) }
            let archived = selected.compactMap { item -> URL? in
                switch item.state {
                case let .done(result): return result.url
                case let .duplicate(_, existing): return existing
                default: return nil
                }
            }
            if !archived.isEmpty {
                Button("Öffnen") { archived.forEach { NSWorkspace.shared.open($0) } }
                Button("Im Archiv zeigen") { model.selectedTab = .archive }
            }
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting(archived.isEmpty ? selected.map(\.url) : archived)
            }
            let failed = selected.filter { if case .failed = $0.state { return true }; return false }
            if !failed.isEmpty {
                Button("Erneut versuchen") { failed.forEach { inbox.retry($0) } }
            }
        } primaryAction: { ids in
            for item in inbox.items where ids.contains(item.id) {
                switch item.state {
                case let .done(result): NSWorkspace.shared.open(result.url)
                case let .duplicate(_, existing): NSWorkspace.shared.open(existing)
                default: break
                }
            }
        }
        .overlay {
            if inbox.items.isEmpty && inbox.arriving.isEmpty {
                Text("Keine Dateien in der Warteschlange")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text("Eingangsordner: \(inbox.folder?.path ?? "–")")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Im Finder öffnen") {
                if let folder = inbox.folder { NSWorkspace.shared.open(folder) }
            }
            if inbox.failedCount > 0 || FileManager.default.fileExists(atPath: inbox.errorFolder?.path ?? "") {
                Button("Fehler-Ordner") {
                    if let folder = inbox.errorFolder { NSWorkspace.shared.open(folder) }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct InboxRow: View {
    let item: InboxService.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer()
            Text(item.added.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(tooltip)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .processing:
            ProgressView().controlSize(.small)
        case let .done(result):
            if result.issues.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .duplicate:
            Image(systemName: "doc.on.doc.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch item.state {
        case .waiting:
            Text("wartet").font(.caption).foregroundStyle(.secondary)
        case let .processing(step):
            Text(step).font(.caption).foregroundStyle(.secondary)
        case let .done(result):
            let head = "Nr. \(Archive.formatNumber(result.number))" + (result.title.isEmpty ? "" : " · \(result.title)")
            if result.issues.isEmpty {
                Text(head).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("\(head) – archiviert, aber: \(result.issues.map(\.message).joined(separator: "; "))")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        case let .failed(message):
            Text("\(message) → Ordner „Fehler“").font(.caption).foregroundStyle(.red).lineLimit(2)
        case let .duplicate(number, _):
            Text("Duplikat von Nr. \(Archive.formatNumber(number)) – nicht erneut archiviert → Ordner „Duplikate“")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private var tooltip: String {
        switch item.state {
        case let .done(result):
            var lines = [result.url.lastPathComponent]
            if !result.summary.isEmpty { lines.append(result.summary) }
            lines += result.issues.map { "⚠︎ " + $0.message }
            return lines.joined(separator: "\n")
        case let .failed(message):
            return message
        case let .duplicate(_, existing):
            return "Bereits archiviert als \(existing.lastPathComponent)\nDoppelklick öffnet das vorhandene Dokument."
        default:
            return item.fileName
        }
    }
}
