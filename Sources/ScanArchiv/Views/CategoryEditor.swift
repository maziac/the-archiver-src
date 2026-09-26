import ScanArchivCore
import SwiftUI

/// Kategorien eines Dokuments bearbeiten: Chips mit ✕, Eingabefeld mit Vorschlägen und Menü aller bekannten
/// Kategorien. „Oberkategorie/Name“ legt eine Unterkategorie an (z. B. „Absender/DAK“).
struct CategoryEditor: View {
    @Binding var categories: [String]
    /// bekannte Kategorien (Startliste + Archiv)
    let known: [String]
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !categories.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(categories, id: \.self) { category in
                        CategoryChip(title: Categories.display(category), selected: true) {
                            categories.removeAll { $0 == category }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Kategorie hinzufügen, z. B. Rechnung oder Absender/DAK", text: $input)
                    .onSubmit { add(input) }
                Menu {
                    menuItems(parent: nil)
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Vorhandene Kategorie wählen")
            }
            if !matches.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(matches, id: \.self) { category in
                        Button(Categories.display(category)) { add(category) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    /// bekannte Kategorien, die zur Eingabe passen (höchstens 8)
    private var matches: [String] {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        return Array(known.filter {
            !categories.contains($0) && $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.prefix(8))
    }

    /// Menü: Oberkategorien mit Untermenü für ihre Unterkategorien
    @ViewBuilder
    private func menuItems(parent: String?) -> some View {
        let children = CategoryTree.children(of: parent, in: known)
        ForEach(children, id: \.self) { path in
            let grandChildren = CategoryTree.children(of: path, in: known)
            if grandChildren.isEmpty {
                Button(Categories.leaf(path)) { add(path) }
                    .disabled(categories.contains(path))
            } else {
                Menu(Categories.leaf(path)) {
                    AnyView(menuItems(parent: path))
                }
            }
        }
    }

    private func add(_ raw: String) {
        let path = Categories.cleanPath(raw)
        input = ""
        guard !path.isEmpty else { return }
        // Schreibweise einer vorhandenen Kategorie übernehmen
        let existing = known.first { $0.compare(path, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let category = existing ?? path
        guard !categories.contains(category) else { return }
        categories.append(category)
        categories.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Baumhilfen für Kategoriepfade.
enum CategoryTree {
    /// direkte Unterkategorien (nil = Wurzeln), sortiert
    static func children(of parent: String?, in paths: [String]) -> [String] {
        var result = Set<String>()
        for path in Categories.expanded(paths) where Categories.parent(path) == parent {
            result.insert(path)
        }
        return result.sorted { Categories.leaf($0).localizedStandardCompare(Categories.leaf($1)) == .orderedAscending }
    }
}

/// Kapsel für eine Kategorie; mit `onRemove` erscheint ein ✕.
struct CategoryChip: View {
    let title: String
    var selected = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .help("Entfernen")
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
    }
}

/// Einfacher Umbruch-Layout: Elemente nebeneinander, bei Platzmangel in die nächste Zeile.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
