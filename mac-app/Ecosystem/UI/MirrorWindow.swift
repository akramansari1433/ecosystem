import AVFoundation
import SwiftUI

/// Hosts the AVSampleBufferDisplayLayer that renders the phone's screen.
private struct VideoLayerView: NSViewRepresentable {
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

struct MirrorWindow: View {
    @Environment(AppState.self) private var appState
    let session: MirrorSession

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                ContentUnavailableView(
                    "Mirroring stopped", systemImage: "iphone.slash",
                    description: Text("Start mirroring from the Ecosystem menu."))
            case .waitingForPhone:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Check your phone")
                        .font(.headline)
                    Text("Tap “Start now” in the dialog on your phone to begin.")
                        .foregroundStyle(.secondary)
                }
            case .streaming:
                VideoLayerView(layer: session.displayLayer)
                    .aspectRatio(session.videoSize, contentMode: .fit)
            case .failed(let reason):
                ContentUnavailableView(
                    "Mirroring failed", systemImage: "exclamationmark.triangle",
                    description: Text(reason))
            }
        }
        .frame(minWidth: 260, minHeight: 420)
        .background(.black)
        .onDisappear { session.stop() }
        .toolbar {
            if session.isActive {
                Button("Stop", systemImage: "stop.circle") { session.stop() }
            } else {
                Button("Start", systemImage: "play.circle") { session.start() }
            }
        }
    }
}
