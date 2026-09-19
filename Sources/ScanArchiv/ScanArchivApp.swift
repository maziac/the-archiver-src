import ScanArchivCore
import SwiftUI

@main
struct ScanArchivApp: App {
    @State private var model: AppModel
    @State private var session: ScanSession
    @State private var inbox: InboxService

    /// Programmversion aus dem Bundle, z. B. „ScanArchiv 1.1 (Build 202609191030)“
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = (info?["CFBundleVersion"] as? String).map { " (Build \($0))" } ?? ""
        return "ScanArchiv \(version)\(build)"
    }

    init() {
        // wird in jedes neu erstellte bzw. geänderte Dokument geschrieben
        DocumentMetadata.appName = Self.versionString
        let model = AppModel()
        let inbox = InboxService(model: model)
        _model = State(initialValue: model)
        _session = State(initialValue: ScanSession(scanner: ScannerService(), model: model))
        _inbox = State(initialValue: inbox)
        // Eingangsordner sofort beim Start einlesen und überwachen
        inbox.start()
    }

    var body: some Scene {
        Window("ScanArchiv", id: "main") {
            @Bindable var model = model
            TabView(selection: $model.selectedTab) {
                ScanView(session: session)
                    .tabItem { Label("Scannen", systemImage: "scanner") }
                    .tag(AppTab.scan)
                InboxView()
                    .tabItem { Label("Eingang", systemImage: "tray.and.arrow.down") }
                    .badge(inbox.waitingCount + inbox.processingCount)
                    .tag(AppTab.inbox)
                SearchView()
                    .tabItem { Label("Archiv", systemImage: "magnifyingglass") }
                    .tag(AppTab.archive)
            }
            .frame(minWidth: 900, minHeight: 600)
            .environment(model)
            .environment(inbox)
        }
        Settings {
            SettingsView()
                .environment(model)
                .environment(inbox)
        }
    }
}
