import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Bridge so drag callbacks (which run outside SwiftUI) reach the live model.
@MainActor
enum AppServices {
    static weak var manager: ConnectionManager?

    nonisolated static func downloadForDrag(
        remotePath: String, name: String
    ) async throws -> URL {
        let model = await MainActor.run { manager?.files }
        guard let model else { throw ConnectionManager.RequestError.notConnected }
        return try await model.downloadForDrag(remotePath: remotePath, name: name)
    }
}

/// Lazy file promise for dragging a phone file into Finder or any app.
///
/// Registers the file under its real content type and suggested name, so the
/// dropped file arrives as "IMG_1234.HEIC" rather than an extensionless "data"
/// blob, and the bytes are only fetched if the user completes the drop.
@MainActor
func phoneFileItemProvider(remotePath: String, name: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = name
    let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    provider.registerFileRepresentation(
        forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
    ) { completion in
        Task {
            do {
                let url = try await AppServices.downloadForDrag(
                    remotePath: remotePath, name: name)
                completion(url, false, nil)
            } catch {
                completion(nil, false, error)
            }
        }
        return nil
    }
    return provider
}

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: FileBrowserModel
    @State private var selection = Set<FsEntry.ID>()

    private let gridThumbEdge = 192
    private let listThumbEdge = 96

    var body: some View {
        NavigationSplitView {
            placesSidebar
        } detail: {
            VStack(spacing: 0) {
                breadcrumbs
                Divider()
                content
                statusBar
            }
            .navigationTitle(model.pathComponents.last ?? "Phone")
            .toolbar { toolbarItems }
            .searchable(text: $model.searchText, prompt: "Search this folder")
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls)
            return true
        }
        .quickLookPreview($model.quickLookURL)
        .task { await model.refresh() }
        .frame(minWidth: 720, minHeight: 420)
    }

    // MARK: sidebar

    private var placesSidebar: some View {
        List {
            Section("Phone") {
                ForEach(Place.all) { place in
                    Button {
                        model.open(place)
                        selection.removeAll()
                    } label: {
                        Label(place.name, systemImage: place.symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Button {
                    model.navigate(toComponent: nil)
                    selection.removeAll()
                } label: {
                    Label("All storage", systemImage: "internaldrive")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 240)
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { model.goBack() }
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
        }
        ToolbarItem {
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Switch between list and icons")
        }
        ToolbarItem {
            Picker("Show", selection: $model.filter) {
                ForEach(FileFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Menu {
                Picker("Sort by", selection: $model.sortField) {
                    ForEach(SortField.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Toggle("Ascending", isOn: $model.sortAscending)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort files")
        }
        ToolbarItem {
            Button("Send files", systemImage: "square.and.arrow.up") { pickAndUpload() }
                .help("Copy files from this Mac into the folder you're viewing")
        }
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if !appState.connected {
            ContentUnavailableView(
                "Phone not connected", systemImage: "iphone.gen3.slash",
                description: Text("Reconnect to browse files."))
        } else if model.isLoading && model.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredEntries.isEmpty {
            emptyState
        } else if model.viewMode == .list {
            listView
        } else {
            gridView
        }
    }

    private var emptyState: some View {
        Group {
            if !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.filter != .all {
                ContentUnavailableView(
                    "No \(model.filter.rawValue.lowercased()) here",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Switch to All to see everything in this folder."))
            } else {
                ContentUnavailableView(
                    "Folder is empty", systemImage: "folder",
                    description: Text("Drop files here to copy them to your phone."))
            }
        }
    }

    private var listView: some View {
        List(selection: $selection) {
            ForEach(model.filteredEntries) { entry in
                listRow(entry).tag(entry.id)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onKeyPress(.space) {
            previewSelection()
            return .handled
        }
    }

    /// Spacebar, Finder-style: preview the first selected file.
    private func previewSelection() {
        if let entry = model.filteredEntries.first(
            where: { selection.contains($0.id) && !$0.isDir }) {
            model.quickLook(entry)
        }
    }

    private func listRow(_ entry: FsEntry) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry, edge: listThumbEdge, side: 38, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 5)
        .onDrag {
            phoneFileItemProvider(
                remotePath: model.remotePath(for: entry), name: entry.name)
        }
        .contextMenu { itemMenu(entry) }
        .onTapGesture(count: 2) { activate(entry) }
        .onAppear { model.loadThumbnailIfNeeded(entry, edge: listThumbEdge) }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 18)],
                spacing: 18
            ) {
                ForEach(model.filteredEntries) { entry in
                    gridCell(entry)
                }
            }
            .padding(18)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            previewSelection()
            return .handled
        }
    }

    private func gridCell(_ entry: FsEntry) -> some View {
        let isSelected = selection.contains(entry.id)
        return VStack(spacing: 8) {
            thumbnail(entry, edge: gridThumbEdge, side: 84, corner: 10)
                .shadow(color: .black.opacity(entry.kind == .image || entry.kind == .video
                                              ? 0.18 : 0), radius: 3, y: 1)
            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onDrag {
            selection = [entry.id]
            return phoneFileItemProvider(
                remotePath: model.remotePath(for: entry), name: entry.name)
        }
        .onTapGesture(count: 2) { activate(entry) }
        .onTapGesture { selection = [entry.id] }
        .contextMenu { itemMenu(entry) }
        .onAppear { model.loadThumbnailIfNeeded(entry, edge: gridThumbEdge) }
        .help(entry.name)
    }

    @ViewBuilder
    private func thumbnail(
        _ entry: FsEntry, edge: Int, side: CGFloat, corner: CGFloat
    ) -> some View {
        if let image = model.thumbnail(for: entry, edge: edge) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: side * 0.3))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(3)
                }
            }
        } else {
            Image(systemName: iconName(for: entry))
                .font(.system(size: side * 0.5, weight: .light))
                .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                .frame(width: side, height: side)
        }
    }

    // MARK: chrome

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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            if let status = model.transferStatus {
                Divider()
                HStack(spacing: 10) {
                    if let progress = model.transferProgress {
                        ProgressView(value: progress)
                            .frame(width: 120)
                        Text("\(status) — \(Int(progress * 100))%")
                            .font(.callout)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(status).font(.callout)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            if let error = model.errorMessage {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Divider()
            HStack {
                Text(itemSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drag files out to save them · drop files in to send them")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var itemSummary: String {
        let count = model.filteredEntries.count
        let base = count == 1 ? "1 item" : "\(count) items"
        return selection.isEmpty ? base : "\(base), \(selection.count) selected"
    }

    // MARK: actions

    /// Right-click menu. Acts on the whole selection when the clicked item is
    /// part of it, otherwise on just that item.
    @ViewBuilder
    private func itemMenu(_ entry: FsEntry) -> some View {
        let targets = selection.contains(entry.id) && selection.count > 1
            ? model.filteredEntries.filter { selection.contains($0.id) }
            : [entry]
        let files = targets.filter { !$0.isDir }

        if entry.isDir && targets.count == 1 {
            Button("Open") { model.enter(entry) }
            Divider()
        }
        if files.count == 1 {
            Button("Quick Look") { model.quickLook(files[0]) }
        }
        if files.count == 1 {
            Button("Save to Downloads") { model.downloadToDownloadsFolder(files[0]) }
            Button("Save As…") { model.saveAs(files[0]) }
        } else if files.count > 1 {
            Button("Save \(files.count) files to Downloads") {
                files.forEach { model.downloadToDownloadsFolder($0) }
            }
        }
        if !files.isEmpty { Divider() }
        Button(targets.count > 1 ? "Copy \(targets.count) names" : "Copy name") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                targets.map(\.name).joined(separator: "\n"), forType: .string)
        }
        Button("Copy path on phone") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                targets.map { model.remotePath(for: $0) }.joined(separator: "\n"),
                forType: .string)
        }
        Divider()
        Button("Refresh") { Task { await model.refresh() } }
    }

    /// Double-click: folders open; files preview in Quick Look (saving stays an
    /// explicit action — drag out, or right-click → Save).
    private func activate(_ entry: FsEntry) {
        if entry.isDir {
            selection.removeAll()
            model.enter(entry)
        } else {
            model.quickLook(entry)
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to copy to your phone"
        if panel.runModal() == .OK {
            model.upload(panel.urls)
        }
    }

    private func subtitle(_ entry: FsEntry) -> String {
        let date = Date(timeIntervalSince1970: Double(entry.mtimeMillis) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        guard !entry.isDir else { return date }
        let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        let folder = model.containingFolder(of: entry)
        return folder.isEmpty ? "\(size) · \(date)" : "\(size) · \(date) · in \(folder)"
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
            case "txt", "md": "doc.text"
            default: "doc"
            }
        }
    }
}
