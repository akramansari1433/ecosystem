import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    let manager: ConnectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: appState.menuBarSymbol)
                Text(appState.statusText)
                    .font(.headline)
            }

            if let code = appState.pairingCode {
                pairingCard(code: code)
            } else if case .foundUnpaired = appState.status {
                Button("Pair with this phone…") {
                    manager.startPairing()
                }
                .buttonStyle(.borderedProminent)
            }

            if appState.connected && appState.paired {
                Button(appState.ringing ? "Stop ringing" : "Ring my phone") {
                    manager.toggleRing()
                }
                Button("Browse phone files…") {
                    openWindow(id: "phone-files")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Divider()

            Button("Quit Ecosystem") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 280)
    }

    private func pairingCard(code: String) -> some View {
        VStack(spacing: 8) {
            Text("Confirm this code matches your phone:")
                .font(.subheadline)
            Text(code)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .kerning(4)
            HStack {
                Button("Cancel") { manager.cancelPairing() }
                Button("They match") { manager.confirmPairing() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
