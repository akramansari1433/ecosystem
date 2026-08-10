import SwiftUI

@main
struct EcosystemApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Ecosystem", systemImage: appState.menuBarSymbol) {
            MenuContent()
                .environment(appState)
        }
    }
}
