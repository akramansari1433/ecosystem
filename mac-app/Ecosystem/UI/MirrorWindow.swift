import AVFoundation
import SwiftUI

/// The video surface. Also the control surface: clicks become taps, drags become
/// swipes, and the scroll wheel becomes flick-scrolling on the phone.
private final class MirrorInputView: NSView {
    let videoLayer: AVSampleBufferDisplayLayer
    var onTap: ((CGPoint, Bool) -> Void)?
    var onSwipe: ((CGPoint, CGPoint, Int) -> Void)?
    var onText: ((String) -> Void)?
    var onKey: ((String) -> Void)?

    private var downPoint: CGPoint?
    private var downTime: Date?
    private var scrollAnchor: CGPoint?
    private var scrollAccumulated: CGFloat = 0
    private var lastScrollSent = Date.distantPast

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .black
        // Take focus so typing goes to the phone without an extra click.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    /// Locks the window to the phone's aspect ratio so the video fills it
    /// completely — no letterbox bars on any edge.
    func applyAspectRatio(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let ratio = NSSize(width: size.width, height: size.height)
        guard window.contentAspectRatio != ratio else { return }
        window.contentAspectRatio = ratio
        var frame = window.frame
        let chrome = frame.height - window.contentLayoutRect.height
        let contentWidth = window.contentLayoutRect.width
        let targetHeight = contentWidth * size.height / size.width + chrome
        frame.origin.y += frame.height - targetHeight
        frame.size.height = targetHeight
        window.setFrame(frame, display: true, animate: false)
    }

    /// Mac keyboard → phone. Printable text is typed into the focused field;
    /// Return/Delete/Escape map to the phone's equivalents.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)   // leave ⌘-shortcuts to the app
            return
        }
        switch event.keyCode {
        case 36, 76: onKey?("enter")
        case 51: onKey?("backspace")
        case 53: onKey?("back")
        default:
            guard let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  })
            else {
                super.keyDown(with: event)
                return
            }
            onText?(text)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = normalized(event)
        downTime = Date()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = downPoint, let time = downTime else { return }
        defer { downPoint = nil; downTime = nil }
        let end = normalized(event)
        let pixels = hypot(
            (end.x - start.x) * bounds.width, (end.y - start.y) * bounds.height)
        let elapsedMs = Int(Date().timeIntervalSince(time) * 1000)
        if pixels < 8 {
            onTap?(start, elapsedMs > 450)
        } else {
            onSwipe?(start, end, min(max(elapsedMs, 60), 1500))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Coalesce wheel deltas into occasional flicks; one swipe per event
        // would flood the phone and scroll erratically.
        if scrollAnchor == nil { scrollAnchor = normalized(event) }
        scrollAccumulated += event.scrollingDeltaY
        guard Date().timeIntervalSince(lastScrollSent) > 0.11,
              abs(scrollAccumulated) > 2, let anchor = scrollAnchor else { return }
        lastScrollSent = Date()
        let travel = max(-0.55, min(0.55, scrollAccumulated / bounds.height * 2.2))
        scrollAccumulated = 0
        scrollAnchor = nil
        let startY = min(max(anchor.y, 0.25), 0.75)
        let endY = min(max(startY + travel, 0.03), 0.97)
        onSwipe?(CGPoint(x: anchor.x, y: startY), CGPoint(x: anchor.x, y: endY), 90)
    }

    /// AppKit's origin is bottom-left; Android's is top-left.
    private func normalized(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x / max(bounds.width, 1), 0), 1),
            y: min(max(1 - point.y / max(bounds.height, 1), 0), 1))
    }
}

private struct MirrorSurface: NSViewRepresentable {
    let session: MirrorSession

    func makeNSView(context: Context) -> NSView {
        let view = MirrorInputView(videoLayer: session.displayLayer)
        view.onTap = { point, long in
            session.tap(x: point.x, y: point.y, longPress: long)
        }
        view.onSwipe = { from, to, duration in
            session.swipe(from: from, to: to, durationMs: duration)
        }
        view.onText = { session.type($0) }
        view.onKey = { session.pressKey($0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MirrorInputView)?.applyAspectRatio(session.videoSize)
    }
}

struct MirrorWindow: View {
    @Environment(AppState.self) private var appState
    let session: MirrorSession

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
            .onDisappear { session.stop() }
            .toolbar {
                if session.phase == .streaming {
                    ToolbarItemGroup {
                        Button("Back", systemImage: "chevron.backward") {
                            session.pressKey("back")
                        }
                        .help("Back (esc)")
                        Button("Home", systemImage: "circle") { session.pressKey("home") }
                        Button("Recents", systemImage: "square.on.square") {
                            session.pressKey("recents")
                        }
                    }
                }
                ToolbarItem {
                    if session.isActive {
                        Button("Stop", systemImage: "stop.circle") { session.stop() }
                    } else {
                        Button("Start", systemImage: "play.circle") { session.start() }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            ContentUnavailableView(
                "Mirroring stopped", systemImage: "iphone.slash",
                description: Text("Press Start to view and control your phone."))
        case .waitingForPhone:
            VStack(spacing: 12) {
                ProgressView()
                Text("Check your phone").font(.headline)
                Text("Tap “Allow mirroring”, then “Start now”.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .streaming:
            // No aspectRatio modifier: the window itself is locked to the phone's
            // ratio, so the video fills every pixel of the content area.
            MirrorSurface(session: session)
        case .failed(let reason):
            ContentUnavailableView(
                "Mirroring failed", systemImage: "exclamationmark.triangle",
                description: Text(reason))
        }
    }

}
