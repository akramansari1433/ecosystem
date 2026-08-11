import AVFoundation
import SwiftUI

private struct CameraSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
    }
}

struct CameraWindow: View {
    @Environment(AppState.self) private var appState
    @Bindable var session: CameraSession

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            controls
                .padding(10)
        }
        .frame(minWidth: 480, minHeight: 320)
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            ContentUnavailableView(
                "Camera off", systemImage: "camera",
                description: Text("Press Start to use the phone's camera here."))
        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting the phone's camera…").foregroundStyle(.secondary)
            }
        case .streaming:
            CameraSurface(layer: session.displayLayer)
                .aspectRatio(session.videoSize, contentMode: .fit)
        case .failed(let reason):
            ContentUnavailableView(
                "Camera unavailable", systemImage: "exclamationmark.triangle",
                description: Text(reason.contains("camera_permission")
                                  || reason.lowercased().contains("allow camera")
                                  ? "Open Ecosystem on the phone and allow camera access."
                                  : reason))
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Lens", selection: $session.lens) {
                ForEach(CameraSession.Lens.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(!session.isActive)

            Spacer()

            if session.isActive {
                Button("Stop", systemImage: "stop.circle") { session.stop() }
            } else {
                Button("Start", systemImage: "play.circle") { session.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
