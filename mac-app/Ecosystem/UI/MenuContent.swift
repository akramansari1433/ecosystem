import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack {
            Text(appState.statusText)
            Divider()
            Button("Quit Ecosystem") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
