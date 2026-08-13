import AVFoundation

/// Plays the PCM chunks the phone captures during mirroring: s16le interleaved
/// stereo 48 kHz on the wire, converted to float on arrival. When the network
/// stalls, the backlog is dropped so audio stays near-live instead of slipping
/// ever further behind the video.
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                       channels: 2)!

    // Touched by the render thread's completion callbacks; hence the lock.
    private let lock = NSLock()
    private var pending = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        do {
            try engine.start()
            player.play()
        } catch {
            // No output device, or it vanished: mirroring continues silently.
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        lock.lock(); pending = 0; lock.unlock()
    }

    var muted: Bool {
        get { engine.mainMixerNode.outputVolume == 0 }
        set { engine.mainMixerNode.outputVolume = newValue ? 0 : 1 }
    }

    func enqueue(pcm16 data: Data) {
        let frames = data.count / 4   // 2 channels × 2 bytes
        guard frames > 0, engine.isRunning,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }

        // More than ~300 ms queued means the link hiccuped; skip until it drains.
        lock.lock()
        let backlog = pending
        lock.unlock()
        guard backlog < 15 else { return }

        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            for i in 0..<frames {
                left[i] = Float(samples[i * 2]) / 32768
                right[i] = Float(samples[i * 2 + 1]) / 32768
            }
        }
        lock.lock(); pending += 1; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }
}
