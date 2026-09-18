import ScanArchivCore
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [DocumentRecord] = []
    @State private var selection = Set<DocumentRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\DocumentRecord.number, order: .reverse)]
    @State private var editing: DocumentRecord?
    @State private var pendingDelete: [DocumentRecord] = []
    @State private var preview = PDFPreviewModel()
    @State private var error: String?

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Schlagworte oder Dokumentnummer …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                Text("\(results.count) Dokument(e)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Menu {
                    Button("Index neu aufbauen") { model.reindex(full: true) }
                    Button("Archivordner öffnen") {
                        if let folder = model.archive?.folder { NSWorkspace.shared.open(folder) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
            titleBatchBar
            Divider()
            if let error = error ?? model.error {
                Text(error).foregroundStyle(.red).padding()
            }
            HSplitView {
                table
                    .frame(minWidth: 440, idealWidth: 620)
                PDFPreviewPane(preview: preview)
                    .frame(minWidth: 320, idealWidth: 480, maxHeight: .infinity)
            }
        }
        // Vorschau folgt der Auswahl; Suchbegriff aus dem Archiv ist die Voreinstellung
        .onChange(of: selection) { _, _ in updatePreview() }
        .onChange(of: query) { _, _ in updatePreview() }
        .onChange(of: results) { _, _ in updatePreview() }
        .task(id: "\(query)|\(model.revision)|\(model.archive?.folder.path ?? "")") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let index = model.index else { return }
            do {
                results = try index.search(query).sorted(using: sortOrder)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: sortOrder) { _, order in results.sort(using: order) }
        .sheet(item: $editing) { record in
            EditDocumentSheet(record: record)
        }
    }

    private var table: some View {
        Table(results, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Nr.", value: \.number) { Text(Archive.formatNumber($0.number)).monospacedDigit() }
                .width(64)
            TableColumn("Datum", value: \.date) { Text(Self.dateFormat.string(from: $0.date)).monospacedDigit() }
                .width(80)
            TableColumn("Dokument") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if !record.summary.isEmpty {
                        Text(record.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    // Trefferausschnitt bei aktiver Suche; ohne Titel/Beschreibung der Textanfang
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty || record.summary.isEmpty {
                        Text(highlighted(record.snippet))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(tooltip(for: record))
            }
            TableColumn("Seiten") { Text("\($0.pages)").monospacedDigit() }
                .width(44)
            TableColumn("Datei") { Text($0.fileName).foregroundStyle(.secondary).lineLimit(2) }
                .width(min: 120, ideal: 180)
        }
        .contextMenu(forSelectionType: DocumentRecord.ID.self) { ids in
            Button("Öffnen") { open(ids) }
            Button("Bearbeiten …") {
                if let id = ids.first { editing = results.first { $0.id == id } }
            }
            .disabled(ids.count != 1)
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
            }
            Divider()
            Button(ids.count > 1 ? "\(ids.count) Dokumente löschen …" : "Löschen …", role: .destructive) {
                pendingDelete = results.filter { ids.contains($0.id) }
            }
        } primaryAction: { ids in
            open(ids)  // Doppelklick
        }
        .onDeleteCommand {  // Entf-Taste bzw. Bearbeiten → Löschen
            pendingDelete = results.filter { selection.contains($0.id) }
        }
        .confirmationDialog(deleteQuestion, isPresented: Binding(
            get: { !pendingDelete.isEmpty },
            set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("In den Papierkorb legen", role: .destructive) {
                do {
                    try model.deleteDocuments(paths: pendingDelete.map(\.path))
                    selection.subtract(pendingDelete.map(\.id))
                } catch {
                    self.error = error.localizedDescription
                }
                pendingDelete = []
            }
            Button("Abbrechen", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Die Datei(en) werden in den Papierkorb gelegt und können dort wiederhergestellt werden. Die Nummern werden nicht neu vergeben.")
        }
    }

    @ViewBuilder
    private var titleBatchBar: some View {
        if let batch = model.titleBatch {
            HStack {
                ProgressView(value: Double(batch.done), total: Double(max(batch.total, 1)))
                    .frame(maxWidth: 240)
                Text("Titel werden erzeugt: \(batch.done) / \(batch.total)")
                    .monospacedDigit()
                Spacer()
                Button("Abbrechen") { model.cancelTitleBatch() }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        } else if model.missingTitleCount > 0, Summarizer.isAvailable {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("\(model.missingTitleCount) Dokument(e) ohne Titel.")
                    .foregroundStyle(.secondary)
                Button("Titel erzeugen") { model.generateMissingTitles() }
                if let result = model.titleBatchResult {
                    Text(result).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        } else if let result = model.titleBatchResult {
            HStack {
                Text(result).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    /// Erstes ausgewähltes Dokument (in Listenreihenfolge) in der Vorschau zeigen.
    private func updatePreview() {
        let shown = results.first { selection.contains($0.id) }
        preview.show(url: shown?.url, query: query)
    }

    private var deleteQuestion: String {
        if pendingDelete.count == 1, let doc = pendingDelete.first {
            return "„\(doc.displayTitle)“ (Nr. \(Archive.formatNumber(doc.number))) löschen?"
        }
        return "\(pendingDelete.count) Dokumente löschen?"
    }

    /// Tooltip: vollständiger Titel und die ganze Beschreibung
    private func tooltip(for record: DocumentRecord) -> String {
        record.summary.isEmpty ? record.displayTitle : "\(record.displayTitle)\n\n\(record.summary)"
    }

    private func open(_ ids: Set<DocumentRecord.ID>) {
        for id in ids { NSWorkspace.shared.open(URL(fileURLWithPath: id)) }
    }

    /// Wandelt die \u{1}…\u{2}-Markierungen des Suchindex in fette Hervorhebung um.
    private func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var current = ""
        func flush() {
            var part = AttributedString(current)
            if bold { part.font = .callout.bold(); part.foregroundColor = .accentColor }
            result += part
            current = ""
        }
        for ch in snippet {
            if ch == "\u{1}" { flush(); bold = true } else if ch == "\u{2}" { flush(); bold = false } else { current.append(ch) }
        }
        flush()
        return result
    }
}

/// Datum, Titel und Beschreibung eines archivierten Dokuments bearbeiten.
private struct EditDocumentSheet: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var title: String
    @State private var summary: String
    @State private var busy = false
    @State private var message: String?

    init(record: DocumentRecord) {
        self.record = record
        _date = State(initialValue: record.date)
        _title = State(initialValue: record.title)
        _summary = State(initialValue: record.summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nr. \(Archive.formatNumber(record.number)) bearbeiten")
                .font(.headline)
            Form {
                DatePicker("Datum", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.field)
                TextField("Titel", text: $title)
                TextField("Beschreibung", text: $summary, axis: .vertical)
                    .lineLimit(3...6)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Text("Die Datei wird passend zu Datum und Titel umbenannt. Der Stempel auf Seite 1 bleibt unverändert.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if Summarizer.isAvailable {
                    Button("Neu vorschlagen", systemImage: "sparkles") { suggest() }
                        .disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func suggest() {
        busy = true
        message = nil
        Task {
            do {
                let suggestion = try await model.suggestion(forPath: record.path)
                title = suggestion.title
                summary = suggestion.summary
                if let date = suggestion.date { self.date = date }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func save() {
        busy = true
        Task {
            do {
                try await model.updateDocument(path: record.path, date: date, title: title, summary: summary)
                dismiss()
            } catch {
                message = error.localizedDescription
                busy = false
            }
        }
    }
}
