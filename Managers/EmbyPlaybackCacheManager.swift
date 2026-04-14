import Foundation

actor EmbyPlaybackCacheManager {
    private var activeDownloads: [String: Task<URL, Error>] = [:]
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
            return destinationURL
        }

        _ = downloadTask(
            key: key,
            track: track,
            source: source,
            session: session,
            service: service,
            destinationURL: destinationURL
        )
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

    private func cacheKey(for track: Track) -> String {
        let sourceComponent = track.sourceId ?? TrackLocator.embyIdentifiers(from: track.url)?.sourceId ?? "unknown-source"
        let itemComponent = track.remoteItemId ?? TrackLocator.embyIdentifiers(from: track.url)?.itemId ?? UUID().uuidString
        let sanitized = "\(sourceComponent)_\(itemComponent)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sanitized
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
            try await service.downloadAudio(
                source: source,
                session: session,
                track: track,
                destinationURL: destinationURL
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
    }
}
