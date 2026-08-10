import SwiftUI

@main
struct EcosystemApp: App {
    @State private var appState: AppState
    @State private var manager: ConnectionManager

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        let manager = ConnectionManager(appState: state)
        _manager = State(initialValue: manager)
        manager.start()
    }

    var body: some Scene {
        MenuBarExtra("Ecosystem", systemImage: appState.menuBarSymbol) {
            MenuContent(manager: manager)
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
