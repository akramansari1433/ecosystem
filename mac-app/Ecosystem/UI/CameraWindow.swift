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
                Text("Starting the phone's camera…").font(.headline)
                Text("Android needs the Ecosystem app open on the phone while the\n"
                     + "camera is in use — it is being brought to the front now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .streaming:
            CameraSurface(layer: session.displayLayer)
                .aspectRatio(session.videoSize, contentMode: .fit)
        case .failed(let reason):
            ContentUnavailableView(
                "Camera unavailable", systemImage: "exclamationmark.triangle",
                description: Text(explain(reason)))
        }
    }

    private func explain(_ reason: String) -> String {
        let text = reason.lowercased()
        if text.contains("allow camera") || text.contains("permission") {
            return "Open Ecosystem on the phone and tap Allow camera, then press Start."
        }
        if text.contains("open ecosystem") || text.contains("foreground") {
            return "Open the Ecosystem app on the phone and keep it on screen, "
                + "then press Start. Android does not allow camera use otherwise."
        }
        return reason
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if session.cameras.isEmpty {
                Text("No cameras reported").foregroundStyle(.secondary)
            } else {
                Picker("Camera", selection: $session.selectedCameraId) {
                    ForEach(session.cameras) { camera in
                        Text(camera.label).tag(camera.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(!session.isActive)

                if !session.zoomOptions.isEmpty {
                    Picker("Zoom", selection: $session.zoom) {
                        ForEach(session.zoomOptions, id: \.self) { step in
                            Text(step == step.rounded() ? "\(Int(step))×" : "\(step)×")
                                .tag(step)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(session.phase != .streaming)
                    .help("Zooming switches to the telephoto lenses")
                }
            }

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
