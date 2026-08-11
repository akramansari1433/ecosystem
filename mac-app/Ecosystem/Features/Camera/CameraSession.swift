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

    enum Lens: String, CaseIterable, Identifiable {
        case back, front
        var id: String { rawValue }
        var label: String { self == .back ? "Back camera" : "Front camera" }
    }

    private unowned let manager: ConnectionManager
    let displayLayer = AVSampleBufferDisplayLayer()

    var phase: Phase = .idle
    var videoSize = CGSize(width: 16, height: 9)
    var lens: Lens = .back {
        didSet {
            guard lens != oldValue, phase == .streaming else { return }
            manager.send(.cameraSwitchLens(.init(lens: lens.rawValue)))
            restart()
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
        streamTask = Task { await run() }
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

    /// Switching lens restarts capture on the phone, so the stream is rebuilt.
    private func restart() {
        streamTask?.cancel()
        let stream = self.stream
        self.stream = nil
        Task { await stream?.closeStream() }
        phase = .starting
        streamTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            await run()
        }
    }

    private func run() async {
        do {
            let reply = try await manager.request(
                .cameraStart(.init(
                    bitrateBps: 6_000_000, fps: 30, lens: lens.rawValue, width: 1280)),
                timeout: 20)
            guard case .cameraStarted(let started) = reply.message else {
                throw ConnectionManager.RequestError.remote("unexpected reply")
            }
            videoSize = CGSize(width: started.width, height: started.height)

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
