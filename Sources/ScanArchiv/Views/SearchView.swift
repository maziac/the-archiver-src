import ScanArchivCore
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [DocumentRecord] = []
    @State private var selection = Set<DocumentRecord.ID>()
    @State private var error: String?

    private static let dateFormat: DateFormatter = {
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
                Button("Index neu aufbauen") { model.reindex(full: true) }
                Button("Ordner öffnen") {
                    if let folder = model.archive?.folder { NSWorkspace.shared.open(folder) }
                }
            }
            .padding(10)
            Divider()
            if let error = error ?? model.error {
                Text(error).foregroundStyle(.red).padding()
            }
            Table(results, selection: $selection) {
                TableColumn("Nr.") { Text(Archive.formatNumber($0.number)).monospacedDigit() }
                    .width(70)
                TableColumn("Datum") { Text(Self.dateFormat.string(from: $0.date)).monospacedDigit() }
                    .width(85)
                TableColumn("Seiten") { Text("\($0.pages)").monospacedDigit() }
                    .width(50)
                TableColumn("Inhalt") { Text(highlighted($0.snippet)).lineLimit(2) }
                TableColumn("Datei") { Text($0.fileName).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 160)
            }
            .contextMenu(forSelectionType: DocumentRecord.ID.self) { ids in
                Button("Öffnen") { open(ids) }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
                }
            } primaryAction: { ids in
                open(ids)  // Doppelklick
            }
        }
        .task(id: "\(query)|\(model.revision)|\(model.archive?.folder.path ?? "")") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let index = model.index else { return }
            do {
                results = try index.search(query)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
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
            if bold { part.font = .body.bold(); part.foregroundColor = .accentColor }
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
