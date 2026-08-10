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
        // Take focus so typing goes to the phone without an extra click.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
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

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct MirrorWindow: View {
    @Environment(AppState.self) private var appState
    let session: MirrorSession

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.phase == .streaming {
                navigationBar
                    .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 300, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { session.stop() }
        .toolbar {
            if session.isActive {
                Button("Stop", systemImage: "stop.circle") { session.stop() }
            } else {
                Button("Start", systemImage: "play.circle") { session.start() }
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
            MirrorSurface(session: session)
                .aspectRatio(session.videoSize, contentMode: .fit)
        case .failed(let reason):
            ContentUnavailableView(
                "Mirroring failed", systemImage: "exclamationmark.triangle",
                description: Text(reason))
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 26) {
            NavButton(icon: "chevron.backward", label: "Back (esc)") {
                session.pressKey("back")
            }
            NavButton(icon: "circle", label: "Home") { session.pressKey("home") }
            NavButton(icon: "square.on.square", label: "Recent apps") {
                session.pressKey("recents")
            }
        }
    }
}

private struct NavButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 28)
        }
        .buttonStyle(.bordered)
        .help(label)
    }
}
