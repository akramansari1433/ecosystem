import AVFoundation
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.akram.ecosystem", category: "camera")

/// Streams the phone's camera to the Mac. Shares the H.264 assembly used by
/// screen mirroring; the difference is the source and the lens control.
@MainActor
@Observable
final class CameraSession {
    enum Phase: Equatable {
        case idle
        case starting
        case streaming
        case failed(String)
    }

    private unowned let manager: ConnectionManager
    let displayLayer = AVSampleBufferDisplayLayer()

    var phase: Phase = .idle
    var videoSize = CGSize(width: 16, height: 9)
    /// Rotation the phone asked for, applied when displaying.
    var rotationDeg: Int = 0

    /// Size as shown, with width and height swapped for a quarter turn.
    var displaySize: CGSize {
        rotationDeg % 180 == 0
            ? videoSize
            : CGSize(width: videoSize.height, height: videoSize.width)
    }

    /// Every camera the phone will let us open, e.g. ultra wide, main, telephoto.
    var cameras: [CameraDeviceInfo] = []

    /// Zoom on the selected camera. Values above 1 hand over to the telephoto
    /// lenses, which Samsung does not expose as separate cameras.
    var zoom: Float = 1 {
        didSet {
            guard zoom != oldValue, phase == .streaming else { return }
            manager.send(.cameraZoom(.init(ratio: zoom)))
        }
    }

    var selectedCamera: CameraDeviceInfo? {
        cameras.first { $0.id == selectedCameraId }
    }

    /// The zoom factors that reach this camera's physical lenses, as reported by
    /// the phone — 0.6×, 1×, 3×, 5× on a phone with four back lenses.
    var zoomOptions: [Float] {
        selectedCamera?.lensSteps ?? []
    }

    /// Empty means "whatever the phone considers its main back camera".
    var selectedCameraId: String = "" {
        didSet {
            guard selectedCameraId != oldValue else { return }
            zoom = zoomOptions.contains(1) || zoomOptions.isEmpty ? 1 : (zoomOptions.first ?? 1)
            if isActive { restart() }
        }
    }

    private var streamTask: Task<Void, Never>?
    private var stream: StreamConnection?

    init(manager: ConnectionManager) {
        self.manager = manager
        displayLayer.videoGravity = .resizeAspect
    }

    var isActive: Bool { phase == .starting || phase == .streaming }

    func start() {
        guard !isActive else { return }
        phase = .starting
        streamTask = Task {
            await loadCameras()
            await run()
        }
    }

    /// Asks the phone which cameras it has, so the picker shows real options.
    func refreshCameras() async {
        await loadCameras()
    }

    private func loadCameras() async {
        guard let reply = try? await manager.request(.cameraList, timeout: 8),
              case .cameraCameras(let payload) = reply.message else { return }
        cameras = payload.cameras
        if selectedCameraId.isEmpty || !payload.cameras.contains(
            where: { $0.id == selectedCameraId }) {
            selectedCameraId = payload.cameras.first?.id ?? ""
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        let stream = self.stream
        self.stream = nil
        Task { await stream?.closeStream() }
        manager.send(.cameraStop)
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        phase = .idle
    }

    /// Choosing another camera restarts capture on the phone.
    private func restart() {
        streamTask?.cancel()
        let stream = self.stream
        self.stream = nil
        Task { await stream?.closeStream() }
        phase = .starting
        streamTask = Task {
            await stream?.closeStream()
            try? await Task.sleep(for: .milliseconds(500))
            await run()
        }
    }

    private func run() async {
        do {
            // Android only allows camera capture while the phone app is on screen,
            // and the phone brings itself to the front when asked — so retry for a
            // few seconds rather than failing the moment it is still in the
            // background or the permission has only just been granted.
            var started: CameraStartedPayload?
            var lastError: String?
            for attempt in 0..<6 {
                if Task.isCancelled { return }
                do {
                    let reply = try await manager.request(
                        .cameraStart(.init(
                            bitrateBps: 6_000_000, cameraId: selectedCameraId,
                            fps: 30, width: 1280, zoom: zoom)),
                        timeout: 20)
                    if case .cameraStarted(let payload) = reply.message {
                        started = payload
                        break
                    }
                    lastError = "unexpected reply"
                } catch ConnectionManager.RequestError.remote(let message) {
                    lastError = message
                }
                phase = .starting
                try await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 2))
            }
            guard let started else {
                phase = .failed(lastError ?? "The phone did not start its camera.")
                return
            }
            videoSize = CGSize(width: started.width, height: started.height)
            rotationDeg = (((started.rotationDeg ?? 0) % 360) + 360) % 360

            let stream = try manager.openStream()
            self.stream = stream
            let assembler = H264Assembler()
            phase = .streaming
            log.info("camera streaming \(started.width)x\(started.height)")

            for try await frame in await stream.frames(token: started.token, kind: "camera") {
                if Task.isCancelled { break }
                switch frame.frameType {
                case BinaryFrames.typeCodecConfig:
                    try assembler.handleConfig(frame.payload)
                    if let dims = assembler.formatDescription.map({
                        CMVideoFormatDescriptionGetDimensions($0)
                    }) {
                        let size = CGSize(width: Int(dims.width), height: Int(dims.height))
                        if size != videoSize {
                            videoSize = size
                            displayLayer.sampleBufferRenderer.flush()
                        }
                    }
                case BinaryFrames.typeKeyframe, BinaryFrames.typeDelta:
                    let sample = try assembler.makeSampleBuffer(
                        payload: frame.payload, ptsMicros: frame.ptsMicros)
                    if displayLayer.sampleBufferRenderer.status == .failed {
                        displayLayer.sampleBufferRenderer.flush()
                    }
                    displayLayer.sampleBufferRenderer.enqueue(sample)
                default:
                    break
                }
            }
            if phase == .streaming { phase = .idle }
        } catch {
            log.warning("camera session ended: \(error.localizedDescription, privacy: .public)")
            if !Task.isCancelled {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
