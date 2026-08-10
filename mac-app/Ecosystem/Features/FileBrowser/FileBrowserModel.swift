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
    var filter: FileFilter = .all

    var filteredEntries: [FsEntry] {
        switch filter {
        case .all: entries
        case .images: entries.filter { $0.isDir || $0.kind == .image }
        case .videos: entries.filter { $0.isDir || $0.kind == .video }
        }
    }

    // MARK: thumbnails

    private(set) var thumbnails: [String: NSImage] = [:]
    private var thumbsInFlight: Set<String> = []
    private var thumbFailures: Set<String> = []

    func thumbnail(for entry: FsEntry) -> NSImage? {
        thumbnails[currentPath + "/" + entry.name]
    }

    func loadThumbnailIfNeeded(_ entry: FsEntry) {
        guard entry.kind == .image || entry.kind == .video else { return }
        let path = currentPath + "/" + entry.name
        guard thumbnails[path] == nil,
              !thumbsInFlight.contains(path),
              !thumbFailures.contains(path) else { return }
        thumbsInFlight.insert(path)
        Task {
            defer { thumbsInFlight.remove(path) }
            guard let reply = try? await manager.request(
                .fsThumb(.init(maxEdge: 96, path: path))),
                case .fsThumbData(let payload) = reply.message,
                let base64 = payload.dataBase64,
                let data = Data(base64Encoded: base64),
                let image = NSImage(data: data)
            else {
                thumbFailures.insert(path)
                return
            }
            thumbnails[path] = image
        }
    }

    private var uploadWaiters: [String: CheckedContinuation<FsTransferResultPayload, Never>] = [:]

    init(manager: ConnectionManager) {
        self.manager = manager
    }

    var currentPath: String {
        ([Self.root] + pathComponents).joined(separator: "/")
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let reply = try await manager.request(.fsList(.init(path: currentPath)))
            guard case .fsEntries(let payload) = reply.message else { return }
            entries = payload.entries
        } catch {
            errorMessage = "Couldn't list \(currentPath): \(error.localizedDescription)"
        }
    }

    func enter(_ entry: FsEntry) {
        guard entry.isDir else { return }
        pathComponents.append(entry.name)
        Task { await refresh() }
    }

    /// Breadcrumb navigation: index nil = root, otherwise keep 0...index.
    func navigate(toComponent index: Int?) {
        if let index {
            pathComponents = Array(pathComponents.prefix(index + 1))
        } else {
            pathComponents = []
        }
        Task { await refresh() }
    }

    // MARK: downloads

    /// Downloads [entry] into the given directory; returns the local file URL.
    func download(_ entry: FsEntry, into directory: URL) async throws -> URL {
        let remotePath = currentPath + "/" + entry.name
        transferStatus = "Downloading \(entry.name)…"
        defer { transferStatus = nil }

        let reply = try await manager.request(.fsDownload(.init(path: remotePath)))
        guard case .fsTransferReady(let ready) = reply.message else {
            throw ConnectionManager.RequestError.notConnected
        }
        let stream = try manager.openStream()
        let destination = uniqueURL(for: entry.name, in: directory)
        let sha = try await stream.download(
            token: ready.token, to: destination, expectedSize: ready.size ?? entry.size)
        manager.send(.fsTransferResult(.init(
            message: nil, ok: true, sha256: sha, token: ready.token)))
        log.info("downloaded \(entry.name) sha=\(sha.prefix(12), privacy: .public)…")
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

    /// Drag-out support: downloads to a temp dir and hands Finder the file.
    func downloadForDrag(name: String, remoteDirectory: String) async throws -> URL {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw ConnectionManager.RequestError.notConnected
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecosystem-drags/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try await download(entry, into: tempDir)
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
        transferStatus = "Uploading \(url.lastPathComponent)…"
        defer { transferStatus = nil }

        let reply = try await manager.request(.fsUpload(.init(destPath: destPath, size: size)))
        guard case .fsTransferReady(let ready) = reply.message else {
            throw ConnectionManager.RequestError.notConnected
        }
        let stream = try manager.openStream()
        try await stream.upload(token: ready.token, from: url)

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
