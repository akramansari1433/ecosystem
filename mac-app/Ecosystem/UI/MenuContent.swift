import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    let manager: ConnectionManager

    @State private var confirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            if let code = appState.pairingCode {
                pairingCard(code: code)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else if case .foundUnpaired = appState.status {
                VStack(spacing: 2) {
                    MenuRow(icon: "qrcode", title: "Pair by scanning…") {
                        open(window: "pair-scan")
                    }
                    MenuRow(icon: "number", title: "Pair with a 6-digit code…") {
                        manager.startPairing()
                    }
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
                    open(window: "phone-files")
                }
                MenuRow(icon: "rectangle.on.rectangle", title: "Mirror phone screen…",
                        enabled: ready) {
                    open(window: "phone-mirror") { manager.mirror.start() }
                }
                MenuRow(icon: "camera", title: "Use phone camera…", enabled: ready) {
                    open(window: "phone-camera") { manager.camera.start() }
                }
            }
            .padding(8)

            Divider()

            footer
                .padding(8)
        }
        .frame(width: 290)
        .onAppear { confirmingForget = false }
    }

    // MARK: footer

    /// Quit and “forget this phone” share one row, but not equal billing: quitting
    /// is routine and keeps the full label, while unpairing is rare and destructive,
    /// so it is a small icon that asks for confirmation in place. (A real `.alert`
    /// dies with the menu-bar panel the moment it loses focus.)
    @ViewBuilder
    private var footer: some View {
        if confirmingForget {
            HStack(spacing: 8) {
                Text("Forget \(appState.phoneName ?? "this phone")?")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { confirmingForget = false }
                Button("Forget") {
                    confirmingForget = false
                    manager.forgetPhone()
                }
                .tint(.red)
            }
            .controlSize(.small)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
        } else {
            HStack(spacing: 4) {
                MenuRow(icon: "power", title: "Quit Ecosystem") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")

                if appState.paired {
                    IconButton(icon: "iphone.slash", help: "Forget this phone") {
                        confirmingForget = true
                    }
                }
            }
        }
    }

    private var ready: Bool { appState.connected && appState.paired }

    /// Dismisses the menu-bar panel first: leaving it hanging over the window it
    /// just opened looks broken, and it swallows the first click.
    private func open(window id: String, then action: (() -> Void)? = nil) {
        dismissMenuBarPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
            action?()
        }
    }

    private func dismissMenuBarPanel() {
        // Close the panel's window directly. Sending `cancelOperation:` with no
        // target also dismissed it, but AppKit rings the system bell whenever an
        // action reaches the end of the responder chain unhandled — that was the
        // beep on every menu click.
        let panels = NSApp.windows.filter { window in
            window.isVisible && (window.className.contains("MenuBarExtra")
                                 || window.className.contains("StatusBar"))
        }
        if panels.isEmpty {
            // Nothing matched (a future macOS may rename the class): dropping
            // activation dismisses the panel too, and is still silent.
            NSApp.deactivate()
        } else {
            panels.forEach { $0.orderOut(nil) }
        }
    }

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

/// Small square icon button for a secondary action sitting beside a full row.
private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .background(hovering ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
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
