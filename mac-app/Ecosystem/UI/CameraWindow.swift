import AVFoundation
import SwiftUI

private struct CameraSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let rotationDeg: Int

    func makeNSView(context: Context) -> NSView {
        let view = RotatingLayerView(videoLayer: layer)
        view.rotationDeg = rotationDeg
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RotatingLayerView)?.rotationDeg = rotationDeg
    }
}

/// Phone camera sensors are mounted sideways, so the encoded frames arrive
/// rotated. Turning them here keeps the phone encoding at its native
/// orientation, which is free, rather than rotating pixels on the phone.
private final class RotatingLayerView: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer

    var rotationDeg: Int = 0 {
        didSet {
            guard rotationDeg != oldValue else { return }
            needsLayout = true
        }
    }

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // A quarter turn means the layer is laid out with width and height
        // swapped, then rotated about its centre to fill the view.
        let quarterTurn = rotationDeg % 180 != 0
        let size = quarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.transform = CATransform3DIdentity
        videoLayer.bounds = CGRect(origin: .zero, size: size)
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if rotationDeg != 0 {
            // Screen coordinates run counter-clockwise on macOS.
            let radians = CGFloat(-rotationDeg) * .pi / 180
            videoLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        }
        CATransaction.commit()
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
        // Load the camera list even before streaming, so the picker is usable.
        .task { await session.refreshCameras() }
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
            CameraSurface(layer: session.displayLayer, rotationDeg: session.rotationDeg)
                .aspectRatio(session.displaySize, contentMode: .fit)
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
