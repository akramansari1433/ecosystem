import AppKit
import CryptoKit
import Foundation

/// Mac side of clipboard sync: polls NSPasteboard (there is no change notification
/// API), sends local copies, applies remote ones. See docs/protocol.md §6.
@MainActor
final class ClipboardSync {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastReceivedHash: Data?
    private var lastAppliedTs: Int64 = 0

    var onLocalCopy: ((ClipboardSetPayload) -> Void)?

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func applyRemote(_ payload: ClipboardSetPayload) {
        guard payload.tsMillis >= lastAppliedTs else { return } // last-writer-wins
        lastAppliedTs = payload.tsMillis
        lastReceivedHash = hash(payload.text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.text, forType: .string)
        lastChangeCount = pasteboard.changeCount // suppress echo of our own write
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        if hash(text) == lastReceivedHash { return } // echo of a remote set
        onLocalCopy?(ClipboardSetPayload(
            text: text, tsMillis: Int64(Date().timeIntervalSince1970 * 1000)))
    }

    private func hash(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}
