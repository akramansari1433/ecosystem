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
    @Bindable var model: FileBrowserModel
    @State private var selection = Set<FsEntry.ID>()

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            content
            statusBar
        }
        .toolbar {
            ToolbarItem {
                Picker("Filter", selection: $model.filter) {
                    ForEach(FileFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Upload…", systemImage: "square.and.arrow.up") { pickAndUpload() }
                    .help("Send files to this folder on the phone")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls)
            return true
        }
        .task { await model.refresh() }
        .frame(minWidth: 560, minHeight: 360)
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
            List(selection: $selection) {
                ForEach(model.filteredEntries) { entry in
                    row(entry)
                        .tag(entry.id)
                }
            }
            .contextMenu(forSelectionType: FsEntry.ID.self) { ids in
                let files = entriesFor(ids).filter { !$0.isDir }
                if !files.isEmpty {
                    Button(files.count == 1
                           ? "Download \"\(files[0].name)\""
                           : "Download \(files.count) files") {
                        files.forEach { model.downloadToDownloadsFolder($0) }
                    }
                }
            } primaryAction: { ids in
                // Double-click: open folders; files are downloaded only via
                // drag or the context menu — never by accident.
                if let entry = entriesFor(ids).first, entry.isDir {
                    model.enter(entry)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ entry: FsEntry) -> some View {
        HStack(spacing: 12) {
            thumbnailView(entry)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !entry.isDir {
                    Text(ByteCountFormatter.string(
                        fromByteCount: entry.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Date(timeIntervalSince1970: Double(entry.mtimeMillis) / 1000)
                .formatted(date: .abbreviated, time: .shortened))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .draggable(PhoneFileDrag(name: entry.name, remoteDirectory: model.currentPath))
        .onAppear { model.loadThumbnailIfNeeded(entry) }
    }

    @ViewBuilder
    private func thumbnailView(_ entry: FsEntry) -> some View {
        if let image = model.thumbnail(for: entry) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .padding(2)
                }
            }
        } else {
            Image(systemName: iconName(for: entry))
                .font(.system(size: 22))
                .foregroundStyle(entry.isDir ? .cyan : .secondary)
                .frame(width: 40, height: 40)
        }
    }

    private var statusBar: some View {
        Group {
            if let status = model.transferStatus {
                Divider()
                HStack(spacing: 8) {
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

    private func entriesFor(_ ids: Set<FsEntry.ID>) -> [FsEntry] {
        model.filteredEntries.filter { ids.contains($0.id) }
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

    private func iconName(for entry: FsEntry) -> String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .other:
            switch (entry.name as NSString).pathExtension.lowercased() {
            case "pdf": "doc.richtext"
            case "apk": "shippingbox"
            case "zip", "rar", "7z": "archivebox"
            default: "doc"
            }
        }
    }
}
