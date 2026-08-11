import AVFoundation
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.akram.ecosystem", category: "mirror")

/// Drives one screen-mirroring session: requests it over the control channel,
/// waits for phone-side consent, then feeds the stream into a display layer.
@MainActor
@Observable
final class MirrorSession {
    enum Phase: Equatable {
        case idle
        case waitingForPhone
        case streaming
        case failed(String)
    }

    private unowned let manager: ConnectionManager
    let displayLayer = AVSampleBufferDisplayLayer()

    var phase: Phase = .idle
    var videoSize = CGSize(width: 9, height: 16)

    private var streamTask: Task<Void, Never>?
    private var stream: StreamConnection?

    init(manager: ConnectionManager) {
        self.manager = manager
        displayLayer.videoGravity = .resizeAspect
    }

    var isActive: Bool { phase == .waitingForPhone || phase == .streaming }

    func start() {
        guard !isActive else { return }
        phase = .waitingForPhone
        streamTask = Task { await run() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        Task { await stream?.closeStream() }
        stream = nil
        manager.send(.mirrorStop)
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        phase = .idle
    }

    // MARK: remote control

    /// Coordinates are normalized 0…1 with the origin at the screen's top-left.
    func tap(x: Double, y: Double, longPress: Bool = false) {
        guard phase == .streaming else { return }
        manager.send(.inputTap(.init(longPress: longPress, x: x, y: y)))
    }

    func swipe(from: CGPoint, to: CGPoint, durationMs: Int) {
        guard phase == .streaming else { return }
        manager.send(.inputSwipe(.init(
            durationMs: durationMs, x1: from.x, x2: to.x, y1: from.y, y2: to.y)))
    }

    func pressKey(_ key: String) {
        guard phase == .streaming else { return }
        manager.send(.inputKey(.init(key: key)))
    }

    /// Dims the phone's panel to minimum while you work from the Mac.
    var phoneDimmed = false {
        didSet {
            guard phoneDimmed != oldValue else { return }
            pressKey(phoneDimmed ? "dim.on" : "dim.off")
        }
    }

    /// One continuous scroll drag: "begin", then "move"s, then "end".
    func scroll(phase: String, at point: CGPoint) {
        guard phase == "end" || self.phase == .streaming else { return }
        manager.send(.inputScroll(.init(phase: phase, x: point.x, y: point.y)))
    }

    /// Types into whatever field has focus on the phone.
    func type(_ text: String) {
        guard phase == .streaming, !text.isEmpty else { return }
        manager.send(.inputText(.init(text: text)))
    }

    private func run() async {
        do {
            // The phone shows a consent dialog once per session; retry until the
            // user accepts it (or we give up after a minute).
            var started: MirrorStartedPayload?
            for attempt in 0..<30 {
                let reply = try await manager.request(
                    .mirrorStart(.init(bitrateBps: 8_000_000, maxLongEdge: 1280)))
                if case .mirrorStarted(let payload) = reply.message {
                    started = payload
                    break
                }
                guard case .mirrorNeedsConsent = reply.message else {
                    throw ConnectionManager.RequestError.remote("unexpected reply")
                }
                if Task.isCancelled { return }
                try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
            }
            guard let started else {
                phase = .failed("The phone didn't approve mirroring. Try again.")
                return
            }
            videoSize = CGSize(width: started.width, height: started.height)
            let stream = try manager.openStream()
            self.stream = stream
            let assembler = H264Assembler()
            phase = .streaming
            log.info("mirror streaming \(started.width)x\(started.height)")

            for try await frame in await stream.frames(token: started.token, kind: "mirror") {
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
            log.warning("mirror session ended: \(error.localizedDescription, privacy: .public)")
            if !Task.isCancelled {
                phase = .failed("Mirroring ended: \(error.localizedDescription)")
            }
        }
    }
}
