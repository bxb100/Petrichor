import Foundation

actor EmbyPlaybackCacheManager {
    static let progressDidChangeNotification = Notification.Name("EmbyPlaybackCacheProgressDidChange")

    private var activeDownloads: [String: Task<URL, Error>] = [:]
    private var downloadProgress: [String: Double] = [:]
    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL

    init() {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectoryURL = cachesRoot.appendingPathComponent("Petrichor/EmbyPlaybackCache", isDirectory: true)
    }

    func playableURL(
        for track: Track,
        source: LibraryDataSource,
        session: EmbySession,
        service: EmbyService
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
            source: source,
            session: session,
            service: service,
            destinationURL: destinationURL
        )

        if shouldWaitForCachedPlayback(of: track) {
            Logger.info("Waiting for cached remote playback for unsupported AVPlayer format: \(track.format)")
            return try await task.value
        }

        return try await service.makePlaybackURL(source: source, session: session, track: track)
    }

    func prefetch(
        track: Track,
        source: LibraryDataSource,
        session: EmbySession,
        service: EmbyService
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
            Logger.error("Failed to create Emby cache directory: \(error)")
            return
        }

        _ = downloadTask(
            key: key,
            track: track,
            source: source,
            session: session,
            service: service,
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
        let sourceComponent = track.sourceId ?? TrackLocator.embyIdentifiers(from: track.url)?.sourceId ?? "unknown-source"
        let itemComponent = track.remoteItemId ?? TrackLocator.embyIdentifiers(from: track.url)?.itemId ?? UUID().uuidString
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
        source: LibraryDataSource,
        session: EmbySession,
        service: EmbyService,
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
            return try await service.downloadAudio(
                source: source,
                session: session,
                track: track,
                destinationURL: destinationURL,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task {
                        await self.publishProgress(progress, for: key)
                    }
                }
            )
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
