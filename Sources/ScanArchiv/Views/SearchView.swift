import ScanArchivCore
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(InboxService.self) private var inbox
    @State private var query = ""
    /// gerade importierte Dokumente – in der Liste mit „neu“ markiert
    @State private var newPaths: Set<String> = []
    @State private var results: [DocumentRecord] = []
    @State private var selection = Set<DocumentRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\DocumentRecord.number, order: .reverse)]
    @State private var editing: DocumentRecord?
    @State private var editingPages: DocumentRecord?
    @State private var pendingDelete: [DocumentRecord] = []
    @State private var preview = PDFPreviewModel()
    @State private var onlyIssues = false
    @State private var error: String?
    /// aktive Tags (UND-verknüpft mit dem Suchfeld)
    @State private var activeTags = Set<UUID>()
    @State private var tagCounts: [UUID: Int] = [:]
    @State private var editingTag: Tag?
    @State private var creatingTag = false
    /// aktive Kategorien (UND-verknüpft; eine Oberkategorie trifft auch ihre Unterkategorien)
    @State private var activeCategories: [String] = []
    /// Trefferzahl je Kategorie unter dem aktuellen Filter
    @State private var categoryCounts: [String: Int] = [:]
    @State private var renamingCategory: String?
    @State private var newCategoryName = ""
    @State private var removingCategory: String?

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            ImportStatusBar(newPaths: $newPaths, query: $query, activeTags: $activeTags, activeCategories: $activeCategories,
                            onlyIssues: $onlyIssues, sortOrder: $sortOrder)
            categoryBar
            tagBar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Schlagworte oder Dokumentnummer …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                Text("\(results.count) Dokument(e)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Toggle(isOn: $onlyIssues) {
                    Text("Nur mit Problemen (\(model.issueCount))")
                }
                .toggleStyle(.button)
                .tint(.orange)
                .disabled(model.issueCount == 0 && !onlyIssues)
                .help("Nur Dokumente zeigen, die geprüft werden sollten: rot bei Fehlern (Texterkennung, Titel, Datum), gelb bei Hinweisen wie der Seitenreihenfolge")
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
                PDFPreviewPane(preview: preview) {
                    if let url = preview.url { editingPages = results.first { $0.url == url } }
                }
                    .frame(minWidth: 320, idealWidth: 480, maxHeight: .infinity)
            }
        }
        .importDrop(inbox)  // PDFs, Bilder und Ordner lassen sich auch hier ablegen
        // Vorschau folgt der Auswahl; Suchbegriff aus dem Archiv ist die Voreinstellung
        .onChange(of: selection) { _, _ in updatePreview() }
        .onChange(of: query) { _, _ in updatePreview() }
        .onChange(of: results) { _, _ in updatePreview() }
        .task(id: "\(query)|\(onlyIssues)|\(activeTagQueries)|\(activeCategories)|\(model.revision)|\(model.archive?.folder.path ?? "")") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let index = model.index else { return }
            do {
                results = try index.search(query, tagQueries: activeTagQueries, categories: activeCategories,
                                           onlyIssues: onlyIssues).sorted(using: sortOrder)
                error = nil
            } catch {
                self.error = "Tag-Suche: \(error.localizedDescription)"
            }
            let (query, tags, categories, onlyIssues) = (query, activeTagQueries, activeCategories, onlyIssues)
            let counts = await Task.detached(priority: .userInitiated) {
                (try? index.categoryCounts(query: query, tagQueries: tags, categories: categories, onlyIssues: onlyIssues)) ?? [:]
            }.value
            if !Task.isCancelled { categoryCounts = counts }
        }
        // Trefferzahlen der Tags im Hintergrund (bei tausenden Dokumenten wenige Millisekunden je Tag)
        .task(id: "\(model.tags)|\(model.revision)") {
            guard let index = model.index else { return }
            let tags = model.tags
            let counts = await Task.detached(priority: .utility) { () -> [UUID: Int] in
                var result: [UUID: Int] = [:]
                let clock = ContinuousClock()
                for tag in tags {
                    var count: Int?
                    let elapsed = clock.measure { count = try? index.count(tagQuery: tag.query) }
                    if let count { result[tag.id] = count }
                    if elapsed > .seconds(2) { break }  // zu langsam: restliche Tags nur mit Namen
                }
                return result
            }.value
            if !Task.isCancelled { tagCounts = counts }
        }
        .onChange(of: model.tags) { _, tags in activeTags.formIntersection(tags.map(\.id)) }
        // Markierung „neu“ gilt nur für die Liste, die „Anzeigen“ eingestellt hat
        .onChange(of: "\(query)|\(activeTags.map(\.uuidString).sorted().joined())|\(activeCategories)|\(onlyIssues)") { _, _ in
            newPaths = []
        }
        .alert("Kategorie umbenennen", isPresented: Binding(
            get: { renamingCategory != nil },
            set: { if !$0 { renamingCategory = nil } })
        ) {
            TextField("Neuer Name", text: $newCategoryName)
            Button("Umbenennen") {
                if let old = renamingCategory { changeCategory(old, to: newCategoryName) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Gilt für alle Dokumente dieser Kategorie. Gibt es den Namen schon, werden beide Kategorien zusammengeführt. Mit „/“ lässt sich eine Unterkategorie angeben, z. B. „Absender/DAK“.")
        }
        .confirmationDialog(
            "Kategorie „\(removingCategory.map(Categories.display) ?? "")“ aus allen Dokumenten entfernen?",
            isPresented: Binding(get: { removingCategory != nil }, set: { if !$0 { removingCategory = nil } })
        ) {
            Button("Entfernen", role: .destructive) {
                if let old = removingCategory { changeCategory(old, to: nil) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Dokumente bleiben erhalten, nur die Kategorie (samt Unterkategorien) wird entfernt.")
        }
        .sheet(item: $editingTag) { tag in TagEditorSheet(tag: tag) }
        .sheet(isPresented: $creatingTag) { TagEditorSheet(tag: nil) }
        .onChange(of: sortOrder) { _, order in results.sort(using: order) }
        .sheet(item: $editing) { record in
            EditDocumentSheet(record: record)
        }
        .sheet(item: $editingPages) { record in
            PageEditorSheet(record: record) {
                if preview.url == record.url { preview.reload() }
            }
        }
    }

    private var table: some View {
        Table(results, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Nr.", value: \.number) { record in
                HStack(spacing: 3) {
                    if newPaths.contains(record.path) {
                        Text("neu")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    if record.hasIssues {
                        Image(systemName: record.issues.symbol).foregroundStyle(record.issues.color).font(.caption)
                    }
                    Text(Archive.formatNumber(record.number)).monospacedDigit()
                        .foregroundStyle(record.issues.color)
                }
            }
            .width(78)
            TableColumn("Datum", value: \.date) { Text(Self.dateFormat.string(from: $0.date)).monospacedDigit() }
                .width(80)
            TableColumn("Dokument") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(record.issues.color)
                        .lineLimit(1)
                    if record.hasIssues {
                        Text(record.issues.map(\.message).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(record.issues.color)
                            .lineLimit(1)
                    }
                    if !record.summary.isEmpty {
                        Text(record.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !record.categories.isEmpty {
                        Text(record.categories.map(Categories.display).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
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
            TableColumn("Datei") { record in
                Text(record.fileName)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(DocumentInfo.tooltip(meta: record.meta, fileName: record.fileName,
                                               fileSize: DocumentInfo.fileSize(of: record.url), pageCount: record.pages))
            }
                .width(min: 120, ideal: 180)
        }
        .contextMenu(forSelectionType: DocumentRecord.ID.self) { ids in
            let single = ids.count == 1 ? results.first { ids.contains($0.id) } : nil
            if let single, single.issues.contains(where: \.isPageOrder) {
                Button("Reihenfolge prüfen …") { editingPages = single }
                Divider()
            }
            Button("Öffnen") { open(ids) }
            Button("Bearbeiten …") {
                if let id = ids.first { editing = results.first { $0.id == id } }
            }
            .disabled(ids.count != 1)
            Button("Seiten bearbeiten …") { editingPages = single }
                .disabled(single?.meta == nil)
            Button("Drucken …") { if let single { DocumentPrinter.print(url: single.url) } }
                .disabled(single == nil)
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
            }
            let withIssues = results.filter { ids.contains($0.id) && $0.hasIssues }
            if !withIssues.isEmpty {
                Button("Als geprüft markieren") {
                    Task {
                        do { try await model.markReviewed(withIssues) } catch { self.error = error.localizedDescription }
                    }
                }
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
                Text("\(batch.kind == .titles ? "Titel" : "Kategorien") werden erzeugt: \(batch.done) / \(batch.total)")
                    .monospacedDigit()
                Spacer()
                Button("Abbrechen") { model.cancelTitleBatch() }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        } else if model.missingTitleCount > 0 || model.missingCategoriesCount > 0, Summarizer.isAvailable {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                if model.missingTitleCount > 0 {
                    Text("\(model.missingTitleCount) Dokument(e) ohne Titel.")
                        .foregroundStyle(.secondary)
                    Button("Titel erzeugen") { model.generateMissingTitles() }
                }
                if model.missingCategoriesCount > 0 {
                    Text("\(model.missingCategoriesCount) Dokument(e) ohne Kategorien.")
                        .foregroundStyle(.secondary)
                    Button("Kategorien erzeugen") { model.generateMissingCategories() }
                }
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

    private var activeTagQueries: [String] {
        model.tags.filter { activeTags.contains($0.id) }.map(\.query)
    }

    /// Kategorien über den Tags: aktive als Chips, darunter verfügbare Oberkategorien mit Trefferzahl;
    /// Oberkategorien mit Unterkategorien öffnen ein Menü.
    private var categoryBar: some View {
        let available = categoryCounts.filter { $0.value > 0 && !activeCategories.contains($0.key) }.map(\.key)
        let roots = CategoryTree.children(of: nil, in: available)
        return HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activeCategories, id: \.self) { category in
                        CategoryChip(title: Categories.display(category), selected: true) {
                            activeCategories.removeAll { $0 == category }
                        }
                        .contextMenu { categoryActions(category) }
                    }
                    if roots.isEmpty && activeCategories.isEmpty {
                        Text("Noch keine Kategorien – sie entstehen beim Scannen und Importieren")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(roots, id: \.self) { root in
                        if CategoryTree.children(of: root, in: available).isEmpty {
                            Button(categoryLabel(root)) { selectCategory(root) }
                                .contextMenu { categoryActions(root) }
                        } else {
                            Menu(categoryLabel(root)) {
                                Button("Alle: \(categoryLabel(root))") { selectCategory(root) }
                                Divider()
                                categoryMenuItems(parent: root, available: available)
                            }
                            .fixedSize()
                            .contextMenu { categoryActions(root) }
                        }
                    }
                }
                .monospacedDigit()
                .padding(.vertical, 2)
            }
            if !activeCategories.isEmpty {
                Button("Alle aufheben") { activeCategories.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func categoryLabel(_ path: String) -> String {
        Categories.leaf(path) + (categoryCounts[path].map { " (\($0))" } ?? "")
    }

    /// Unterkategorien als Menüeinträge; weitere Ebenen als Untermenüs.
    private func categoryMenuItems(parent: String, available: [String]) -> AnyView {
        AnyView(ForEach(CategoryTree.children(of: parent, in: available), id: \.self) { path in
            if CategoryTree.children(of: path, in: available).isEmpty {
                Button(categoryLabel(path)) { selectCategory(path) }
            } else {
                Menu(categoryLabel(path)) {
                    Button("Alle: \(categoryLabel(path))") { selectCategory(path) }
                    Divider()
                    categoryMenuItems(parent: path, available: available)
                }
            }
        })
    }

    @ViewBuilder
    private func categoryActions(_ category: String) -> some View {
        Button("Umbenennen …") {
            newCategoryName = category
            renamingCategory = category
        }
        Button("Aus allen Dokumenten entfernen …", role: .destructive) { removingCategory = category }
    }

    /// Kategorie auswählen; eine gewählte Ober- oder Unterkategorie derselben Linie wird ersetzt.
    private func selectCategory(_ path: String) {
        activeCategories.removeAll { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") || $0 == path }
        activeCategories.append(path)
    }

    private func changeCategory(_ old: String, to new: String?) {
        let target = new.map(Categories.cleanPath)
        if target == old || target?.isEmpty == true { return }
        Task {
            do {
                try await model.renameCategory(old, to: target)
                activeCategories = activeCategories.compactMap { active in
                    guard active == old || active.hasPrefix(old + "/") else { return active }
                    guard let target, !target.isEmpty else { return nil }
                    return target + active.dropFirst(old.count)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Tags als Schaltflächen über dem Suchfeld; Klick schaltet den Filter an/aus.
    private var tagBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if model.tags.isEmpty {
                        Text("Noch keine Tags – mit „+“ eine gespeicherte Suche anlegen")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(model.tags) { tag in
                        Toggle(isOn: Binding(
                            get: { activeTags.contains(tag.id) },
                            set: { on in if on { activeTags.insert(tag.id) } else { activeTags.remove(tag.id) } })
                        ) {
                            Text(tagCounts[tag.id].map { "\(tag.name) (\($0))" } ?? tag.name)
                                .monospacedDigit()
                        }
                        .toggleStyle(.button)
                        .help(tag.query)
                        .contextMenu {
                            Button("Bearbeiten …") { editingTag = tag }
                            Button("Löschen", role: .destructive) {
                                activeTags.remove(tag.id)
                                try? model.removeTag(tag)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if !activeTags.isEmpty {
                Button("Alle aufheben") { activeTags.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            Button { creatingTag = true } label: { Image(systemName: "plus") }
                .help("Neuen Tag anlegen")
                .disabled(model.tagStore == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
        var parts = [record.displayTitle]
        if !record.summary.isEmpty { parts.append(record.summary) }
        if record.hasIssues {
            parts.append("Zu prüfen:\n" + record.issues.map { "⚠︎ " + $0.message }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
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
/// Zeigt im Archiv, was der Eingang gerade tut, und bietet die frisch archivierten Dokumente an.
private struct ImportStatusBar: View {
    @Environment(InboxService.self) private var inbox
    @Environment(AppModel.self) private var model
    @Binding var newPaths: Set<String>
    @Binding var query: String
    @Binding var activeTags: Set<UUID>
    @Binding var activeCategories: [String]
    @Binding var onlyIssues: Bool
    @Binding var sortOrder: [KeyPathComparator<DocumentRecord>]

    private var busy: Bool { inbox.waitingCount + inbox.processingCount > 0 || inbox.copying != nil }

    var body: some View {
        if busy {
            bar(color: .accentColor) {
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 120)
                Text(runningText).monospacedDigit()
                Spacer()
                Button("Eingang zeigen") { model.selectedTab = .inbox }
            }
        } else if let batch = inbox.lastBatch, batch.total > 0 {
            bar(color: batch.failed > 0 ? .red : (batch.duplicates > 0 ? .orange : .accentColor)) {
                Image(systemName: batch.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(batch.failed > 0 ? Color.red : (batch.duplicates > 0 ? .orange : .green))
                Text(doneText(batch))
                Spacer()
                if !batch.archivedPaths.isEmpty {
                    Button("Anzeigen") { show(batch) }
                }
                if batch.failed + batch.duplicates > 0 {
                    Button("Eingang zeigen") { model.selectedTab = .inbox }
                }
                Button("Ausblenden") { inbox.dismissLastBatch() }
            }
        }
    }

    private func bar<Content: View>(color: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.10))
    }

    private var done: Int { inbox.currentBatch?.total ?? 0 }
    private var total: Int { done + inbox.waitingCount + inbox.processingCount }
    private var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    private var runningText: String {
        var parts: [String] = []
        if let copying = inbox.copying { parts.append("kopiere \(copying.done) von \(copying.total)") }
        parts.append("Import: \(done) von \(total)")
        if let batch = inbox.currentBatch, batch.failed > 0 { parts.append("\(batch.failed) Fehler") }
        return parts.joined(separator: " · ")
    }

    private func doneText(_ batch: InboxService.Batch) -> String {
        var parts: [String] = []
        let n = batch.archivedPaths.count
        if n > 0 { parts.append(n == 1 ? "1 Dokument archiviert" : "\(n) Dokumente archiviert") }
        if batch.duplicates > 0 { parts.append("\(batch.duplicates) Duplikat(e)") }
        if batch.failed > 0 { parts.append("\(batch.failed) Fehler") }
        return parts.joined(separator: " · ")
    }

    /// Filter aufheben, nach Nummer sortieren und die neuen Dokumente markieren.
    private func show(_ batch: InboxService.Batch) {
        query = ""
        activeTags.removeAll()
        activeCategories.removeAll()
        onlyIssues = false
        sortOrder = [KeyPathComparator(\DocumentRecord.number, order: .reverse)]
        newPaths = Set(batch.archivedPaths)
        inbox.dismissLastBatch()
    }
}

private struct EditDocumentSheet: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var title: String
    @State private var summary: String
    @State private var categories: [String]
    @State private var busy = false
    @State private var message: String?
    /// Werte stammen aus „Neu vorschlagen“ (Apple Intelligence)
    @State private var suggested = false

    init(record: DocumentRecord) {
        self.record = record
        _date = State(initialValue: record.date)
        _title = State(initialValue: record.title)
        _summary = State(initialValue: record.summary)
        _categories = State(initialValue: record.categories)
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
                LabeledContent("Kategorien") {
                    CategoryEditor(categories: $categories, known: model.knownCategories)
                        .disabled(record.meta == nil)
                }
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
                suggested = true
                title = suggestion.title
                summary = suggestion.summary
                categories = suggestion.categories
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
                // Geänderte Angaben gelten als von Hand gesetzt
                let dateChanged = !Calendar.current.isDate(date, inSameDayAs: record.date)
                let textChanged = title != record.title || summary != record.summary
                try await model.updateDocument(path: record.path, date: date, title: title, summary: summary,
                                               titleSource: textChanged ? (suggested ? .ai : .manual) : nil,
                                               dateSource: dateChanged ? (suggested ? .ai : .manual) : nil,
                                               categories: categories != record.categories || (record.meta?.categories == nil && suggested)
                                                   ? categories : nil)
                dismiss()
            } catch {
                message = error.localizedDescription
                busy = false
            }
        }
    }
}
