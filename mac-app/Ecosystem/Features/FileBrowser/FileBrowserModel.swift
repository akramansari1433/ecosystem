import AppKit
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.akram.ecosystem", category: "files")

extension FsEntry: Identifiable {
    var id: String { name + (isDir ? "/" : "") }

    var kind: FileKind {
        if isDir { return .folder }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp": return .image
        case "mp4", "mkv", "mov", "webm", "3gp", "avi": return .video
        case "mp3", "m4a", "ogg", "wav", "flac", "opus": return .audio
        default: return .other
        }
    }
}

enum FileKind {
    case folder, image, video, audio, other
}

enum FileFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case images = "Images"
    case videos = "Videos"
    var id: String { rawValue }
}

enum ViewMode: String {
    case list, grid
}

enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case date = "Date modified"
    case size = "Size"
    var id: String { rawValue }
}

/// Shortcuts to the folders that actually matter on an Android phone.
struct Place: Identifiable, Hashable {
    let name: String
    let symbol: String
    let components: [String]
    var id: String { components.joined(separator: "/") }

    static let all: [Place] = [
        Place(name: "Camera", symbol: "camera", components: ["DCIM", "Camera"]),
        Place(name: "Screenshots", symbol: "square.dashed",
              components: ["DCIM", "Screenshots"]),
        Place(name: "Downloads", symbol: "arrow.down.circle", components: ["Download"]),
        Place(name: "WhatsApp", symbol: "bubble.left.and.bubble.right",
              components: ["Android", "media", "com.whatsapp", "WhatsApp", "Media"]),
        Place(name: "Pictures", symbol: "photo", components: ["Pictures"]),
        Place(name: "Movies", symbol: "film", components: ["Movies"]),
        Place(name: "Music", symbol: "music.note", components: ["Music"]),
        Place(name: "Documents", symbol: "doc", components: ["Documents"]),
    ]
}

/// State + operations behind the phone-files window.
@MainActor
@Observable
final class FileBrowserModel {
    static let root = "/storage/emulated/0"

    private unowned let manager: ConnectionManager

    var pathComponents: [String] = []
    var entries: [FsEntry] = []
    var isLoading = false
    var errorMessage: String?
    var transferStatus: String?
    var filter: FileFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            entries = []
            Task { await refresh() }
        }
    }

    var searchText = ""
    var sortField: SortField = .name
    var sortAscending = true
    var transferProgress: Double?

    var viewMode: ViewMode = ViewMode(
        rawValue: UserDefaults.standard.string(forKey: "fileViewMode") ?? "list") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "fileViewMode") }
    }

    /// Search text applied to whatever the current mode loaded (a folder listing
    /// for All, or a recursive media sweep for Images/Videos), then sorted.
    var filteredEntries: [FsEntry] {
        var result = entries
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return result.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let ordered = switch sortField {
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: a.mtimeMillis < b.mtimeMillis
            case .size: a.size < b.size
            }
            return sortAscending ? ordered : !ordered
        }
    }

    var canGoBack: Bool { !pathComponents.isEmpty }

    func goBack() {
        guard canGoBack else { return }
        pathComponents.removeLast()
        entries = []
        Task { await refresh() }
    }

    func open(_ place: Place) {
        pathComponents = place.components
        entries = []
        searchText = ""
        Task { await refresh() }
    }

    // MARK: thumbnails

    private(set) var thumbnails: [String: NSImage] = [:]
    private var thumbsInFlight: Set<String> = []
    private var thumbFailures: Set<String> = []

    func thumbnail(for entry: FsEntry, edge: Int) -> NSImage? {
        thumbnails[cacheKey(entry, edge)]
    }

    func loadThumbnailIfNeeded(_ entry: FsEntry, edge: Int) {
        guard entry.kind == .image || entry.kind == .video else { return }
        let path = remotePath(for: entry)
        let key = cacheKey(entry, edge)
        guard thumbnails[key] == nil,
              !thumbsInFlight.contains(key),
              !thumbFailures.contains(key),
              // Thumbnails share the control connection with everything else;
              // a few at a time keeps listings and transfers responsive.
              thumbsInFlight.count < 4 else { return }
        thumbsInFlight.insert(key)
        Task {
            defer { thumbsInFlight.remove(key) }
            guard let reply = try? await manager.request(
                .fsThumb(.init(maxEdge: edge, path: path))),
                case .fsThumbData(let payload) = reply.message,
                let base64 = payload.dataBase64,
                let data = Data(base64Encoded: base64),
                let image = NSImage(data: data)
            else {
                thumbFailures.insert(key)
                return
            }
            thumbnails[key] = image
        }
    }

    private func cacheKey(_ entry: FsEntry, _ edge: Int) -> String {
        "\(remotePath(for: entry))#\(edge)"
    }

    private var uploadWaiters: [String: CheckedContinuation<FsTransferResultPayload, Never>] = [:]

    init(manager: ConnectionManager) {
        self.manager = manager
    }

    var currentPath: String {
        ([Self.root] + pathComponents).joined(separator: "/")
    }

    /// Listings already seen this session, keyed by path + filter. Revisits show
    /// instantly from cache while a silent refresh replaces them if stale.
    private var listingCache: [String: [FsEntry]] = [:]

    func refresh() async {
        errorMessage = nil
        let requestedPath = currentPath
        let requestedFilter = filter
        let cacheKey = "\(requestedPath)|\(requestedFilter.rawValue)"
        if let cached = listingCache[cacheKey] {
            entries = cached
        } else {
            isLoading = true
        }
        defer { isLoading = false }
        do {
            let reply: InboundEnvelope
            switch requestedFilter {
            case .all:
                reply = try await manager.request(.fsList(.init(path: requestedPath)))
            case .images, .videos:
                // Media views sweep the whole subtree, so they can take a while.
                reply = try await manager.request(
                    .fsSearch(.init(
                        kinds: [requestedFilter == .images ? "image" : "video"],
                        maxDepth: 8, path: requestedPath)),
                    timeout: 90)
            }
            // Ignore replies for a folder/mode we already navigated away from.
            guard requestedPath == currentPath, requestedFilter == filter else { return }
            guard case .fsEntries(let payload) = reply.message else {
                entries = []
                errorMessage = "Unexpected reply for \(requestedPath)"
                return
            }
            entries = payload.entries
            listingCache[cacheKey] = payload.entries
        } catch {
            // Never keep a stale listing: showing the previous folder's rows made
            // repeated clicks append the same folder to the path over and over.
            guard requestedPath == currentPath, requestedFilter == filter else { return }
            entries = []
            errorMessage = "Couldn't open \(requestedPath): \(error.localizedDescription)"
        }
    }

    func enter(_ entry: FsEntry) {
        guard entry.isDir else { return }
        pathComponents.append(entry.name)
        entries = []
        Task { await refresh() }
    }

    /// Breadcrumb navigation: index nil = root, otherwise keep 0...index.
    func navigate(toComponent index: Int?) {
        if let index {
            pathComponents = Array(pathComponents.prefix(index + 1))
        } else {
            pathComponents = []
        }
        entries = []
        Task { await refresh() }
    }

    // MARK: downloads

    /// Absolute path on the phone for an entry in the current view (handles the
    /// relative paths that recursive media searches return).
    func remotePath(for entry: FsEntry) -> String {
        currentPath + "/" + (entry.relPath ?? entry.name)
    }

    /// The folder an entry lives in, relative to the current view ("" if direct).
    func containingFolder(of entry: FsEntry) -> String {
        guard let rel = entry.relPath else { return "" }
        let parts = rel.split(separator: "/").dropLast()
        return parts.joined(separator: "/")
    }

    /// Downloads [entry] into the given directory; returns the local file URL.
    func download(_ entry: FsEntry, into directory: URL) async throws -> URL {
        try await download(
            remotePath: remotePath(for: entry), name: entry.name,
            expectedSize: entry.size, into: directory, saveAs: nil)
    }

    /// Downloads any phone path; [saveAs] overrides the destination file URL.
    func download(
        remotePath: String, name: String, expectedSize: Int64,
        into directory: URL, saveAs: URL?
    ) async throws -> URL {
        transferStatus = "Downloading \(name)"
        transferProgress = 0
        defer { transferStatus = nil; transferProgress = nil }

        let reply = try await manager.request(.fsDownload(.init(path: remotePath)))
        guard case .fsTransferReady(let ready) = reply.message else {
            throw ConnectionManager.RequestError.notConnected
        }
        let stream = try manager.openStream()
        let destination = saveAs ?? uniqueURL(for: name, in: directory)
        let total = max(ready.size ?? expectedSize, 1)
        let sha = try await stream.download(
            token: ready.token, to: destination, expectedSize: ready.size ?? expectedSize,
            onProgress: { [weak self] received in
                Task { @MainActor in self?.transferProgress = Double(received) / Double(total) }
            })
        manager.send(.fsTransferResult(.init(
            message: nil, ok: true, sha256: sha, token: ready.token)))
        log.info("downloaded \(name) sha=\(sha.prefix(12), privacy: .public)…")
        return destination
    }

    func downloadToDownloadsFolder(_ entry: FsEntry) {
        Task {
            do {
                let downloads = FileManager.default
                    .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                _ = try await download(entry, into: downloads)
            } catch {
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Quick Look

    /// Bound to `.quickLookPreview`; setting it opens the system preview panel.
    var quickLookURL: URL?

    /// Previews already fetched this session, keyed by path + mtime.
    private var quickLookCache: [String: URL] = [:]

    func quickLook(_ entry: FsEntry) {
        guard !entry.isDir else { return }
        let path = remotePath(for: entry)
        let key = "\(path)#\(entry.mtimeMillis)"
        if let cached = quickLookCache[key],
           FileManager.default.fileExists(atPath: cached.path) {
            quickLookURL = cached
            return
        }
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ecosystem-previews/\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                let url = try await download(
                    remotePath: path, name: entry.name, expectedSize: entry.size,
                    into: dir, saveAs: nil)
                quickLookCache[key] = url
                quickLookURL = url
            } catch {
                errorMessage = "Preview failed: \(error.localizedDescription)"
            }
        }
    }

    func saveAs(_ entry: FsEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.message = "Save \(entry.name) from your phone"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await download(
                    remotePath: remotePath(for: entry), name: entry.name,
                    expectedSize: entry.size,
                    into: url.deletingLastPathComponent(), saveAs: url)
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    /// Drag-out support: downloads to a temp dir and hands Finder the real file.
    func downloadForDrag(remotePath path: String, name: String) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecosystem-drags/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try await download(
            remotePath: path, name: name, expectedSize: 0, into: tempDir, saveAs: nil)
    }

    // MARK: uploads

    func upload(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    try await uploadOne(url)
                } catch {
                    errorMessage = "Upload of \(url.lastPathComponent) failed: " +
                        error.localizedDescription
                }
            }
            await refresh()
        }
    }

    private func uploadOne(_ url: URL) async throws {
        let size = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let destPath = currentPath + "/" + url.lastPathComponent
        transferStatus = "Uploading \(url.lastPathComponent)"
        transferProgress = 0
        defer { transferStatus = nil; transferProgress = nil }

        let reply = try await manager.request(.fsUpload(.init(destPath: destPath, size: size)))
        guard case .fsTransferReady(let ready) = reply.message else {
            throw ConnectionManager.RequestError.notConnected
        }
        let stream = try manager.openStream()
        let total = max(size, 1)
        try await stream.upload(
            token: ready.token, from: url,
            onProgress: { [weak self] sent in
                Task { @MainActor in self?.transferProgress = Double(sent) / Double(total) }
            })

        let result = await withCheckedContinuation { cont in
            uploadWaiters[ready.token] = cont
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.uploadWaiters.removeValue(forKey: ready.token)?
                    .resume(returning: FsTransferResultPayload(
                        message: "timeout", ok: false, sha256: nil, token: ready.token))
            }
        }
        guard result.ok else {
            throw ConnectionManager.RequestError.remote(result.message ?? "phone rejected file")
        }
        log.info("uploaded \(url.lastPathComponent)")
    }

    /// Called by ConnectionManager when the phone reports an upload result.
    func handleTransferResult(_ payload: FsTransferResultPayload) {
        uploadWaiters.removeValue(forKey: payload.token)?.resume(returning: payload)
    }

    private func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let suffixed = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            counter += 1
        }
        return candidate
    }
}
