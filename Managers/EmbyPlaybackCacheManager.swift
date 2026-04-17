import Foundation

struct RemotePlaybackProvider: Sendable {
    let playbackURL: @Sendable (Track) async throws -> URL
    let downloadAudio: @Sendable (Track, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
}

actor RemotePlaybackCacheManager {
    static let progressDidChangeNotification = Notification.Name("RemotePlaybackCacheProgressDidChange")

    private var activeDownloads: [String: Task<URL, Error>] = [:]
    private var downloadProgress: [String: Double] = [:]
    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL

    init() {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectoryURL = cachesRoot.appendingPathComponent("Petrichor/RemotePlaybackCache", isDirectory: true)
    }

    func playableURL(
        for track: Track,
        provider: RemotePlaybackProvider
    ) async throws -> URL {
        let key = cacheKey(for: track)
        let destinationURL = cachedFileURL(for: track)

        try ensureCacheDirectoryExists()

        if fileManager.fileExists(atPath: destinationURL.path) {
            publishProgress(1, for: key)
            return destinationURL
        }

        let task = downloadTask(
            key: key,
            track: track,
            provider: provider,
            destinationURL: destinationURL
        )

        if shouldWaitForCachedPlayback(of: track) {
            Logger.info("Waiting for cached remote playback for unsupported AVPlayer format: \(track.format)")
            return try await task.value
        }

        return try await provider.playbackURL(track)
    }

    func prefetch(
        track: Track,
        provider: RemotePlaybackProvider
    ) async {
        let key = cacheKey(for: track)
        let destinationURL = cachedFileURL(for: track)

        if fileManager.fileExists(atPath: destinationURL.path) {
            publishProgress(1, for: key)
            return
        }

        do {
            try ensureCacheDirectoryExists()
        } catch {
            Logger.error("Failed to create remote playback cache directory: \(error)")
            return
        }

        _ = downloadTask(
            key: key,
            track: track,
            provider: provider,
            destinationURL: destinationURL
        )
    }

    func trimCache(keeping tracks: [Track]) async {
        let keysToKeep = Set(tracks.compactMap { track -> String? in
            guard track.isRemote else { return nil }
            return cacheKey(for: track)
        })

        guard let cachedFiles = try? fileManager.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in cachedFiles {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if !keysToKeep.contains(filename) && activeDownloads[filename] == nil {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func cachedFileURL(for track: Track) -> URL {
        let fileExtension = track.format.isEmpty ? "audio" : track.format.lowercased()
        return cacheDirectoryURL.appendingPathComponent("\(cacheKey(for: track)).\(fileExtension)")
    }

    static func progressKey(for track: Track) -> String {
        let identifiers = TrackLocator.remoteIdentifiers(from: track.url)
        let sourceComponent = track.sourceId ?? identifiers?.sourceId ?? "unknown-source"
        let itemComponent = track.remoteItemId ?? identifiers?.itemId ?? UUID().uuidString
        return "\(sourceComponent)_\(itemComponent)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    func progress(for track: Track) -> Double? {
        let key = cacheKey(for: track)
        return downloadProgress[key]
    }

    private func cacheKey(for track: Track) -> String {
        Self.progressKey(for: track)
    }

    private func shouldWaitForCachedPlayback(of track: Track) -> Bool {
        let format = track.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !format.isEmpty else { return false }
        return !AudioFormat.canStreamRemotelyWithAVPlayer(format)
    }

    private func ensureCacheDirectoryExists() throws {
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
    }

    private func downloadTask(
        key: String,
        track: Track,
        provider: RemotePlaybackProvider,
        destinationURL: URL
    ) -> Task<URL, Error> {
        if fileManager.fileExists(atPath: destinationURL.path) {
            return Task { destinationURL }
        }

        if let activeTask = activeDownloads[key] {
            return activeTask
        }

        let task = Task<URL, Error> {
            self.publishProgress(0, for: key)
            return try await provider.downloadAudio(track, destinationURL) { [weak self] progress in
                guard let self else { return }
                Task {
                    await self.publishProgress(progress, for: key)
                }
            }
        }
        activeDownloads[key] = task

        Task {
            _ = try? await task.value
            await self.clearActiveDownload(for: key)
        }

        return task
    }

    private func clearActiveDownload(for key: String) async {
        activeDownloads[key] = nil
        if downloadProgress[key] != 1 {
            downloadProgress.removeValue(forKey: key)
        }
    }

    private func publishProgress(_ progress: Double, for key: String) {
        let normalizedProgress = max(0, min(1, progress))
        downloadProgress[key] = normalizedProgress

        Task { @MainActor in
            NotificationCenter.default.post(
                name: Self.progressDidChangeNotification,
                object: nil,
                userInfo: [
                    "key": key,
                    "progress": normalizedProgress
                ]
            )
        }
    }
}
