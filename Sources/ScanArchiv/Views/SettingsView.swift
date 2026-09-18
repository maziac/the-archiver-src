import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.archivePath) private var archivePath = SettingsKey.defaultArchivePath
    @AppStorage(SettingsKey.dpi) private var dpi = 300
    @AppStorage(SettingsKey.color) private var color = false
    @AppStorage(SettingsKey.rotateBacks) private var rotateBacks = false
    @AppStorage(SettingsKey.jpegQuality) private var jpegQuality = 0.7

    var body: some View {
        Form {
            Section("Archiv") {
                LabeledContent("Ordner") {
                    HStack {
                        Text(archivePath).lineLimit(1).truncationMode(.middle)
                        Button("Wählen …") { chooseFolder() }
                    }
                }
            }
            Section("Scan") {
                Picker("Auflösung", selection: $dpi) {
                    Text("200 dpi").tag(200)
                    Text("300 dpi (empfohlen)").tag(300)
                    Text("600 dpi").tag(600)
                }
                Toggle("Farbe (sonst Graustufen)", isOn: $color)
                Toggle("Rückseiten automatisch um 180° drehen", isOn: $rotateBacks)
                Text("Einschalten, wenn der Stapel über die kurze Kante gewendet wird und die Rückseiten auf dem Kopf stehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("JPEG-Qualität") {
                    Slider(value: $jpegQuality, in: 0.4...0.95, step: 0.05)
                    Text(String(format: "%.0f %%", jpegQuality * 100)).monospacedDigit().frame(width: 44)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: archivePath)
        if panel.runModal() == .OK, let url = panel.url {
            archivePath = url.path
            model.openArchive()
        }
    }
}
