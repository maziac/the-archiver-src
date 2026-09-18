import SwiftUI

/// Miniaturen in der fertigen Reihenfolge; Seiten lassen sich drehen oder entfernen.
struct PagePreviewView: View {
    @Bindable var session: ScanSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(session.pages.count) Seite(n) in Originalreihenfolge")
                    .font(.headline)
                Text("Klick auf eine Seite dreht sie um 180°.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Verwerfen", role: .destructive) { session.reset() }
                Button("Speichern") { session.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.pages.isEmpty)
            }
            .padding(10)
            Divider()
            MetadataForm(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumb(page: page, number: index + 1)
                            .onTapGesture { session.toggleRotation(page) }
                            .contextMenu {
                                Button("Um 180° drehen") { session.toggleRotation(page) }
                                Button("Seite entfernen", role: .destructive) { session.remove(page) }
                            }
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Datum, Titel und Beschreibung – vorgeschlagen aus dem Text, frei bearbeitbar.
private struct MetadataForm: View {
    @Bindable var session: ScanSession

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Datum").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                HStack {
                    DatePicker("Datum", selection: $session.documentDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                    Text(dateHint).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    status
                }
            }
            GridRow {
                Text("Titel").foregroundStyle(.secondary)
                TextField("z. B. Stromrechnung Stadtwerke 2026", text: $session.title)
                    .font(.title3)
            }
            GridRow {
                Text("Beschreibung").foregroundStyle(.secondary)
                TextField("Kurzbeschreibung", text: $session.summary, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var dateHint: String {
        switch session.dateSource {
        case .document: return "aus dem Dokument"
        case .today: return "heute – kein Datum im Text gefunden"
        case .manual: return "manuell"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.suggestionState {
        case .idle:
            EmptyView()
        case .recognizing:
            ProgressView().controlSize(.small)
            Text("Texterkennung …").foregroundStyle(.secondary)
        case .suggesting:
            ProgressView().controlSize(.small)
            Text("Vorschlag wird erstellt …").foregroundStyle(.secondary)
        case .done:
            Button("Neu vorschlagen", systemImage: "sparkles") { session.resuggest() }
        case let .unavailable(reason):
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Button("Erneut versuchen") { session.resuggest() }
        }
    }
}

private struct PageThumb: View {
    let page: ScannedPage
    let number: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(page.rotated180 ? 180 : 0))
                .frame(height: 200)
                .background(Color.white)
                .shadow(radius: 2)
                .animation(.easeInOut(duration: 0.2), value: page.rotated180)
            Text("Seite \(number) · \(page.isBack ? "Rückseite" : "Vorderseite")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
