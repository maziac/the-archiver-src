import ScanArchivCore
import SwiftUI

/// Tag anlegen oder bearbeiten: Name + Suchausdruck, mit Live-Prüfung und Trefferzahl.
struct TagEditorSheet: View {
    let original: Tag?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var query: String
    @State private var status: Status = .checking
    @State private var saveError: String?

    enum Status: Equatable {
        case checking
        case valid(Int)
        case invalid(String)
    }

    init(tag: Tag?) {
        original = tag
        _name = State(initialValue: tag?.name ?? "")
        _query = State(initialValue: tag?.query ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Neuer Tag" : "Tag bearbeiten").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("z. B. Rente"))
                TextField("Suche", text: $query, prompt: Text("(\"Rente\" AND \"DRV\") OR \"Rentenversicherung\""), axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.columns)

            statusView

            GroupBox("So funktioniert die Suche") {
                VStack(alignment: .leading, spacing: 4) {
                    help("Rente", "genau dieses Wort (Groß-/Kleinschreibung und Umlaute egal)")
                    help("rente*", "Wortanfang: Rente, Rentenbescheid, …")
                    help("*rente", "Wortende: Altersrente, Witwenrente, …")
                    help("*rente*", "enthält: Altersrentenbescheid, …")
                    help("\"Deutsche Rentenversicherung\"", "Wortfolge")
                    help("A AND B · A OR B · A NOT B", "auch UND · ODER · NICHT; ohne Operator gilt AND")
                    help("( … )", "Klammern zum Gruppieren")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Tags filtern nur – sie stehen nicht im Dokument und werden in der Anzeige nicht markiert. Mehrere aktive Tags und das Suchfeld werden UND-verknüpft.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }

            HStack {
                if let original {
                    Button("Löschen", role: .destructive) {
                        try? model.removeTag(original)
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: query) {
            status = .checking
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let text = query
            let index = model.index
            let result = await Task.detached { () -> Status in
                do {
                    try TagQuery.validate(text)
                    return .valid(try index?.count(tagQuery: text) ?? 0)
                } catch {
                    return .invalid(error.localizedDescription)
                }
            }.value
            if !Task.isCancelled { status = result }
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .valid = status { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Prüfe …").foregroundStyle(.secondary) }
        case let .valid(count):
            Label("Gültig – \(count == 1 ? "1 Dokument" : "\(count) Dokumente")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .invalid(message):
            Label(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Suchausdruck eingeben" : message,
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(query.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.orange)
        }
    }

    private func help(_ example: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(example).font(.system(.callout, design: .monospaced)).frame(width: 220, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func save() {
        var tag = original ?? Tag(name: "", query: "")
        tag.name = name.trimmingCharacters(in: .whitespaces)
        tag.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try model.saveTag(tag)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
