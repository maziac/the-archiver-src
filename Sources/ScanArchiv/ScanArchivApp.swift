import SwiftUI

@main
struct ScanArchivApp: App {
    @State private var model: AppModel
    @State private var session: ScanSession

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _session = State(initialValue: ScanSession(scanner: ScannerService(), model: model))
    }

    var body: some Scene {
        Window("ScanArchiv", id: "main") {
            TabView {
                ScanView(session: session)
                    .tabItem { Label("Scannen", systemImage: "scanner") }
                SearchView()
                    .tabItem { Label("Archiv", systemImage: "magnifyingglass") }
            }
            .frame(minWidth: 900, minHeight: 600)
            .environment(model)
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
