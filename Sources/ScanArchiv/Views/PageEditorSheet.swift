import PDFKit
import ScanArchivCore
import SwiftUI

/// „Seiten bearbeiten“ für ein archiviertes Dokument: Reihenfolge per Ziehen, Drehen per Klick.
/// Gespeichert wird inkrementell (`Archive.rearrange`); der Stempel wandert auf die neue erste Seite.
struct PageEditorSheet: View {
    let record: DocumentRecord
    /// nach erfolgreichem Speichern (z. B. Vorschau neu laden)
    var onSaved: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable, Equatable {
        /// Index der Seite im gespeicherten Dokument
        let id: Int
        /// zusätzliche Drehung im Uhrzeigersinn
        var rotation = 0
    }

    @State private var items: [Item] = []
    @State private var thumbnails: [Int: CGImage] = [:]
    @State private var saving = false
    @State private var error: String?
    /// Höhe der Miniaturen (Regler, gemerkt – gilt auch für die Scan-Vorschau)
    @AppStorage(SettingsKey.pageThumbHeight) private var thumbHeight = SettingsKey.defaultPageThumbHeight

    private var changed: Bool {
        items.map(\.id) != Array(items.indices) || items.contains { $0.rotation % 360 != 0 }
    }

    /// Reihenfolge wie im Original (nur bei beim Import umsortierten Dokumenten)
    private var originalOrder: [Int]? {
        guard let pageOrder = record.meta?.pageOrder, pageOrder.count == items.count else { return nil }
        let order = (0..<pageOrder.count).compactMap { pageOrder.firstIndex(of: $0) }
        return order.count == pageOrder.count ? order : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Seiten bearbeiten – Nr. \(Archive.formatNumber(record.number))").font(.headline)
                Text("Ziehen ändert die Reihenfolge · Klick dreht um 180° · Rechtsklick dreht um 90°. Der Stempel kommt immer auf die erste Seite.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let issue = record.issues.first(where: \.isPageOrder) {
                    Label(issue.message, systemImage: issue.symbol)
                        .font(.callout)
                        .foregroundStyle(issue.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbHeight * 0.72), spacing: 16)], spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        EditorThumb(image: thumbnails[item.id], rotation: item.rotation, height: thumbHeight,
                                    label: label(position: position, item: item)) { id in
                            withAnimation { move(id, to: item.id) }
                        }
                        .onTapGesture { rotate(item, by: 180) }
                        .contextMenu {
                            Button("90° nach rechts drehen", systemImage: "rotate.right") { rotate(item, by: 90) }
                            Button("90° nach links drehen", systemImage: "rotate.left") { rotate(item, by: -90) }
                            Button("Um 180° drehen") { rotate(item, by: 180) }
                        }
                        .draggable(String(item.id)) {
                            if let image = thumbnails[item.id] {
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(height: 120)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 320)
            Divider()
            HStack {
                if let originalOrder {
                    Button("Wie im Original") {
                        withAnimation { items = originalOrder.map { id in items.first { $0.id == id } ?? Item(id: id) } }
                    }
                    .help("Reihenfolge der importierten Datei, vor der automatischen Korrektur")
                }
                Button("Zurücksetzen") { withAnimation { items = items.indices.map { Item(id: $0) } } }
                    .disabled(!changed)
                PageSizeSlider(height: $thumbHeight)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                    .help(changed ? "Neue Reihenfolge/Drehung speichern" : "Reihenfolge bestätigen – der Reihenfolge-Vermerk verschwindet")
            }
            .padding(16)
        }
        .frame(minWidth: 820, idealWidth: 1200, minHeight: 640, idealHeight: 900)
        .task { await load() }
    }

    private func label(position: Int, item: Item) -> String {
        let moved = item.id != position ? " (bisher \(item.id + 1))" : ""
        return "Seite \(position + 1)\(moved)"
    }

    private func rotate(_ item: Item, by degrees: Int) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].rotation = ((items[i].rotation + degrees) % 360 + 360) % 360
    }

    private func move(_ id: Int, to target: Int) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    private func load() async {
        guard let document = PDFDocument(url: record.url) else {
            error = "Das PDF lässt sich nicht öffnen."
            return
        }
        items = (0..<document.pageCount).map { Item(id: $0) }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            // Miniatur in der angezeigten Lage (Seitendrehung eingerechnet)
            // groß genug, dass sich auch kleine Seitenzahlen lesen lassen
            let image = page.thumbnail(of: CGSize(width: 1400, height: 1400), for: .cropBox)
            thumbnails[i] = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            await Task.yield()
        }
    }

    private func save() {
        saving = true
        error = nil
        let order = items.map(\.id)
        let rotations = items.map(\.rotation)
        Task {
            do {
                try await model.rearrangePages(record, order: order, rotations: rotations)
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// Regler für die Größe der Seitenminiaturen (Seiten bearbeiten, Scan-Vorschau).
struct PageSizeSlider: View {
    @Binding var height: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc").imageScale(.small)
            Slider(value: $height, in: SettingsKey.pageThumbHeightRange).frame(width: 160)
            Image(systemName: "doc").imageScale(.large)
        }
        .foregroundStyle(.secondary)
        .help("Größe der Seiten")
    }
}

private struct EditorThumb: View {
    let image: CGImage?
    let rotation: Int
    let height: Double
    let label: String
    /// eine andere Seite (ID) wurde hier abgelegt
    let onDrop: (Int) -> Void
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(decorative: ImageTools.rotated(image, clockwise: rotation), scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(height: height)
            .background(Color.white)
            .shadow(radius: 2)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(dropTargeted ? 1 : 0)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { dropped, _ in
            guard let id = dropped.first.flatMap(Int.init) else { return false }
            onDrop(id)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
