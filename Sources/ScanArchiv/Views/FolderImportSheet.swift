import ScanArchivCore
import SwiftUI

/// Dialog beim Ablegen von Ordnern: Unterordner einbeziehen? Welche Dateitypen?
struct FolderImportSheet: View {
    let folders: [URL]
    let onImport: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage("folderImportSubfolders") private var includeSubfolders = true
    @AppStorage("folderImportPDF") private var includePDF = true
    @AppStorage("folderImportImages") private var includeImages = true
    @State private var result: FolderScan.Result?

    private var options: FolderScan.Options {
        .init(includeSubfolders: includeSubfolders, pdf: includePDF, images: includeImages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(folders.count == 1 ? "Ordner importieren" : "\(folders.count) Ordner importieren", systemImage: "folder")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(folders, id: \.self) { folder in
                    Text(folder.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Toggle("Unterordner einbeziehen", isOn: $includeSubfolders)
            VStack(alignment: .leading, spacing: 6) {
                Text("Dateitypen").foregroundStyle(.secondary)
                Toggle("PDF-Dateien", isOn: $includePDF)
                Toggle("Bilder (JPEG, PNG, TIFF, HEIC, …)", isOn: $includeImages)
            }

            Group {
                if let result {
                    Text("Gefunden: \(count(result.pdfs.count, "PDF", "PDFs")), \(count(result.images.count, "Bild", "Bilder"))")
                        .monospacedDigit()
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Ordner wird durchsucht …") }
                }
            }
            .foregroundStyle(.secondary)

            Text("Die Dateien werden in den Eingang kopiert und dort nacheinander verarbeitet – jede Datei wird ein eigenes Dokument. Die Originale bleiben unverändert; bereits archivierte Dateien werden als Duplikat erkannt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importLabel) {
                    if let result { onImport(result.all) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((result?.all.isEmpty ?? true))
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: options) {
            result = nil
            let folders = folders, options = options
            let found = await Task.detached(priority: .userInitiated) { FolderScan.files(in: folders, options: options) }.value
            if !Task.isCancelled { result = found }
        }
    }

    private var importLabel: String {
        guard let result else { return "Übernehmen" }
        return result.all.count == 1 ? "1 Datei übernehmen" : "\(result.all.count) Dateien übernehmen"
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}
