import SwiftUI
import UniformTypeIdentifiers

/// Drag-out payload: Finder receives a file promise; the download happens
/// lazily when the user actually drops.
struct PhoneFileDrag: Codable, Transferable {
    let name: String
    let remoteDirectory: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { drag in
            let url = try await AppServices.downloadForDrag(drag)
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }
}

/// Bridge so Transferable's static context can reach the live model.
@MainActor
enum AppServices {
    static weak var manager: ConnectionManager?

    nonisolated static func downloadForDrag(_ drag: PhoneFileDrag) async throws -> URL {
        let model = await MainActor.run { manager?.files }
        guard let model else { throw ConnectionManager.RequestError.notConnected }
        return try await model.downloadForDrag(
            name: drag.name, remoteDirectory: drag.remoteDirectory)
    }
}

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    let model: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            content
            if let status = model.transferStatus {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout)
                    Spacer()
                }
                .padding(8)
            }
            if let error = model.errorMessage {
                Divider()
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .toolbar {
            Button("Upload…", systemImage: "square.and.arrow.up") { pickAndUpload() }
                .help("Send files to this folder on the phone")
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls)
            return true
        }
        .task { await model.refresh() }
        .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder
    private var content: some View {
        if !appState.connected {
            ContentUnavailableView(
                "Phone not connected", systemImage: "iphone.gen3.slash",
                description: Text("Connect to your phone to browse its files."))
        } else if model.isLoading && model.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.entries) { entry in
                row(entry)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: FsEntry) -> some View {
        HStack {
            Image(systemName: entry.isDir ? "folder.fill" : iconName(for: entry.name))
                .foregroundStyle(entry.isDir ? .cyan : .secondary)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if !entry.isDir {
                Text(ByteCountFormatter.string(
                    fromByteCount: entry.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 80, alignment: .trailing)
            }
            Text(Date(timeIntervalSince1970: Double(entry.mtimeMillis) / 1000),
                 style: .date)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(width: 110, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDir {
                model.enter(entry)
            } else {
                model.downloadToDownloadsFolder(entry)
            }
        }
        .draggable(PhoneFileDrag(name: entry.name, remoteDirectory: model.currentPath))
        .contextMenu {
            if !entry.isDir {
                Button("Download to Downloads") {
                    model.downloadToDownloadsFolder(entry)
                }
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Phone") { model.navigate(toComponent: nil) }
                    .buttonStyle(.plain)
                    .fontWeight(model.pathComponents.isEmpty ? .semibold : .regular)
                ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(name) { model.navigate(toComponent: index) }
                        .buttonStyle(.plain)
                        .fontWeight(index == model.pathComponents.count - 1
                                    ? .semibold : .regular)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to send to the phone"
        if panel.runModal() == .OK {
            model.upload(panel.urls)
        }
    }

    private func iconName(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic": "photo"
        case "mp4", "mkv", "mov", "webm": "film"
        case "mp3", "m4a", "ogg", "wav", "flac": "music.note"
        case "pdf": "doc.richtext"
        case "apk": "shippingbox"
        case "zip", "rar", "7z": "archivebox"
        default: "doc"
        }
    }
}
