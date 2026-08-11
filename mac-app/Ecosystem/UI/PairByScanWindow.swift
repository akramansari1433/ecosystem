import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows a QR code the phone scans to pair. Nothing to type, nothing to compare:
/// being able to see this screen is the proof that the two devices belong together.
struct PairByScanWindow: View {
    @Environment(AppState.self) private var appState
    let manager: ConnectionManager

    @State private var payload: String = ""

    var body: some View {
        VStack(spacing: 18) {
            if appState.paired {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("Paired with \(appState.phoneName ?? "your phone")")
                        .font(.headline)
                    Text("You can close this window.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Scan this with your phone")
                    .font(.headline)

                qrImage
                    .frame(width: 240, height: 240)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 4) {
                    Text("On the phone, open Ecosystem and tap "
                         + "“Scan QR code from Mac”.")
                    Text("The code expires after a few minutes.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .multilineTextAlignment(.center)

                Button("Show a new code") { payload = manager.makeScanOffer() }
                    .buttonStyle(.link)
            }
        }
        .padding(28)
        .frame(minWidth: 340, minHeight: 420)
        .task {
            if payload.isEmpty { payload = manager.makeScanOffer() }
        }
    }

    @ViewBuilder
    private var qrImage: some View {
        if let image = Self.qrCode(from: payload) {
            Image(nsImage: image)
                .interpolation(.none)      // keep the modules crisp
                .resizable()
        } else {
            ProgressView()
        }
    }

    /// CoreImage generates the code, so there is no third-party dependency.
    private static func qrCode(from string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 240, height: 240))
    }
}
