import ScanArchivCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(InboxService.self) private var inbox
    @AppStorage(SettingsKey.inboxPath) private var inboxPath = SettingsKey.defaultInboxPath
    @AppStorage(SettingsKey.archivePath) private var archivePath = SettingsKey.defaultArchivePath
    @AppStorage(SettingsKey.dpi) private var dpi = 300
    @AppStorage(SettingsKey.rotateBacks) private var rotateBacks = false
    @AppStorage(SettingsKey.autoOrient) private var autoOrient = true
    @AppStorage(SettingsKey.scanPreset) private var scanPreset = SizePreset.kb150
    @AppStorage(SettingsKey.scanColorMode) private var scanColorMode = ColorMode.gray
    @AppStorage(SettingsKey.pdfPreset) private var pdfPreset = SizePreset.original
    @AppStorage(SettingsKey.imagePreset) private var imagePreset = SizePreset.kb150
    @AppStorage(SettingsKey.importColorMode) private var importColorMode = ColorMode.original

    var body: some View {
        Form {
            Section("Archiv") {
                LabeledContent("Ordner") {
                    HStack {
                        Text(archivePath).lineLimit(1).truncationMode(.middle)
                        Button("Wählen …") {
                            if let url = chooseFolder(startingAt: archivePath) {
                                FolderAccess.store(url, forKey: SettingsKey.archivePath)
                                model.openArchive()
                                inbox.start()
                            }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Eingangsordner") {
                    HStack {
                        Text(inboxPath).lineLimit(1).truncationMode(.middle)
                        Button("Wählen …") {
                            if let url = chooseFolder(startingAt: inboxPath) {
                                FolderAccess.store(url, forKey: SettingsKey.inboxPath)
                                inbox.start()
                            }
                        }
                    }
                }
            } header: {
                Text("Eingang")
            } footer: {
                Text("Dateien in diesem Ordner werden automatisch archiviert und danach in den Papierkorb gelegt. Nicht verarbeitbare Dateien landen im Unterordner „Fehler“.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Scan") {
                Picker("Auflösung", selection: $dpi) {
                    Text("200 dpi").tag(200)
                    Text("300 dpi (empfohlen)").tag(300)
                    Text("600 dpi").tag(600)
                }
                Picker("Farbe", selection: $scanColorMode) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0 == .original ? "Farbe" : $0.label).tag($0) }
                }
                Toggle("Ausrichtung automatisch erkennen", isOn: $autoOrient)
                Text("Seiten, deren Text quer oder auf dem Kopf steht, werden in der Vorschau aufrecht gedreht. Seiten ohne erkennbaren Text bleiben, wie sie sind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Rückseiten automatisch um 180° drehen", isOn: $rotateBacks)
                Text("Einschalten, wenn der Stapel über die kurze Kante gewendet wird und die Rückseiten auf dem Kopf stehen. Gilt für Rückseiten, bei denen die automatische Erkennung nichts findet (z. B. ohne Text).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                presetPicker("Größe", selection: $scanPreset)
            }
            Section {
                presetPicker("Importierte PDFs", selection: $pdfPreset)
                presetPicker("Importierte Bilder", selection: $imagePreset)
                Picker("Farbe bei Importen", selection: $importColorMode) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0 == .original ? "Original beibehalten" : $0.label).tag($0) }
                }
            } header: {
                Text("Kompression beim Import")
            } footer: {
                Text("Umgewandelt werden nur Seiten, die ein Bild sind (Scans); Seiten mit echtem Text bleiben unverändert. Ist die umgewandelte Datei nicht kleiner, wird das Original verwendet. Schwarz-Weiß ist ideal für reine Textseiten, macht Fotos und Logos aber grob.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Über") {
                LabeledContent("Version", value: ScanArchivApp.versionString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func presetPicker(_ label: String, selection: Binding<SizePreset>) -> some View {
        Picker(label, selection: selection) {
            ForEach(SizePreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
    }

    private func chooseFolder(startingAt path: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
