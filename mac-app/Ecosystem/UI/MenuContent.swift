import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    let manager: ConnectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            if let code = appState.pairingCode {
                pairingCard(code: code)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else if case .foundUnpaired = appState.status {
                MenuRow(icon: "link", title: "Pair with this phone…") {
                    manager.startPairing()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()

            VStack(spacing: 2) {
                MenuRow(
                    icon: appState.ringing ? "bell.slash.fill" : "bell.and.waves.left.and.right",
                    title: appState.ringing ? "Stop ringing" : "Ring my phone",
                    enabled: ready
                ) {
                    manager.toggleRing()
                }
                MenuRow(icon: "folder", title: "Browse phone files…", enabled: ready) {
                    openWindow(id: "phone-files")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuRow(icon: "rectangle.on.rectangle", title: "Mirror phone screen…",
                        enabled: ready) {
                    openWindow(id: "phone-mirror")
                    NSApp.activate(ignoringOtherApps: true)
                    manager.mirror.start()
                }
            }
            .padding(8)

            Divider()

            MenuRow(icon: "power", title: "Quit Ecosystem") {
                NSApplication.shared.terminate(nil)
            }
            .padding(8)
            .keyboardShortcut("q")
        }
        .frame(width: 290)
    }

    private var ready: Bool { appState.connected && appState.paired }

    // MARK: header

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(ready ? Color.accentColor.gradient : Color.gray.gradient)
                    .frame(width: 36, height: 36)
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 2)
        }
    }

    private var deviceTitle: String {
        appState.phoneName ?? appState.discoveredPhone ?? "No phone found"
    }

    private var statusSubtitle: String {
        switch appState.status {
        case .connected: "Connected"
        case .searching: appState.paired
            ? "Looking for your phone…"
            : "Open Ecosystem on your phone to pair"
        case .foundUnpaired: "Found — not paired yet"
        case .pairing: "Pairing…"
        case .error(let message): message
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .connected: .green
        case .pairing, .foundUnpaired: .orange
        case .error: .red
        case .searching: .secondary.opacity(0.5)
        }
    }

    // MARK: pairing

    private func pairingCard(code: String) -> some View {
        VStack(spacing: 10) {
            Text("Confirm this code matches your phone")
                .font(.subheadline)
            Text(code)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .kerning(5)
            HStack(spacing: 8) {
                Button("Cancel") { manager.cancelPairing() }
                    .frame(maxWidth: .infinity)
                Button("They match") { manager.confirmPairing() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Uniform, hover-highlighted action row, aligned like native menu items.
private struct MenuRow: View {
    let icon: String
    let title: String
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background(
                hovering && enabled ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
    }
}
