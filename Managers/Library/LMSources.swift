import Foundation

extension LibraryManager {
    func loadDataSources() {
        dataSources = databaseManager.loadAllDataSources()
    }

    func passwordForDataSource(_ source: LibraryDataSource) -> String {
        KeychainManager.retrieve(key: KeychainManager.Keys.embyPasswordKey(for: source.id)) ?? ""
    }

    func saveEmbySource(_ source: LibraryDataSource, password: String) async -> Bool {
        let resolvedPassword: String
        if password.isEmpty {
            resolvedPassword = passwordForDataSource(source)
        } else {
            resolvedPassword = password
        }

        guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resolvedPassword.isEmpty else {
            await MainActor.run {
                NotificationManager.shared.addMessage(.warning, "Please fill in the Emby source name, host, username, and password.")
            }
            return false
        }

        var mutableSource = source
        mutableSource.updatedAt = Date()

        do {
            let session = try await embyService.authenticate(source: mutableSource, password: resolvedPassword)
            mutableSource.userId = session.userId
            mutableSource.serverId = session.serverId
            mutableSource.lastSyncError = nil
            let savedSourceName = mutableSource.name

            try await databaseManager.saveDataSource(mutableSource)
            KeychainManager.save(key: KeychainManager.Keys.embyPasswordKey(for: mutableSource.id), value: resolvedPassword)
            KeychainManager.save(key: KeychainManager.Keys.embyAccessTokenKey(for: mutableSource.id), value: session.accessToken)

            await MainActor.run {
                self.loadDataSources()
                NotificationManager.shared.addMessage(.info, "Saved Emby source '\(savedSourceName)'.")
            }

            await syncEmbySource(mutableSource, forceFavoriteRefresh: true, showNotifications: false)
            return true
        } catch {
            Logger.error("Failed to save Emby source: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
            }
            return false
        }
    }

    func deleteDataSource(_ source: LibraryDataSource) async {
        do {
            await cancelEmbyEnrichmentTask(for: source.id)
            try await databaseManager.deleteDataSource(source.id)
            KeychainManager.delete(key: KeychainManager.Keys.embyPasswordKey(for: source.id))
            KeychainManager.delete(key: KeychainManager.Keys.embyAccessTokenKey(for: source.id))

            await MainActor.run {
                self.loadDataSources()
                self.loadMusicLibrary()
                NotificationManager.shared.addMessage(.info, "Removed Emby source '\(source.name)'.")
            }
        } catch {
            Logger.error("Failed to delete data source: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, "Failed to remove Emby source '\(source.name)'.")
            }
        }
    }

    func syncRemoteSourcesOnLaunch() async {
        let sources = dataSources.filter { $0.kind == .emby }
        guard !sources.isEmpty else { return }

        for source in sources {
            await syncEmbySource(source, forceFavoriteRefresh: false, showNotifications: false)
        }
    }

    func syncEmbySource(
        _ source: LibraryDataSource,
        forceFavoriteRefresh: Bool = false,
        showNotifications: Bool = true
    ) async {
        await cancelEmbyEnrichmentTask(for: source.id)

        do {
            let session = try await validSession(for: source)
            let items = try await embyService.fetchAllAudioItems(source: source, session: session)
            let favoriteIDs = try await favoriteItemIDs(for: source, session: session, forceRefresh: forceFavoriteRefresh)
            let tracks = items.compactMap { buildTrack(from: $0, source: source, favoriteIDs: favoriteIDs) }

            try await databaseManager.replaceTracks(for: source, tracks: tracks)
            try await databaseManager.updateDataSourceSyncState(
                sourceId: source.id,
                lastSyncedAt: Date(),
                lastSyncError: nil,
                userId: session.userId,
                serverId: session.serverId
            )

            await MainActor.run {
                self.loadDataSources()
                self.loadMusicLibrary()
                self.refreshDiscoverTracks()
                if showNotifications {
                    NotificationManager.shared.addMessage(.info, "Synced Emby source '\(source.name)' (\(tracks.count) tracks).")
                }
            }

            await startEmbyEnrichmentTask(for: source)
        } catch {
            Logger.error("Failed to sync Emby source '\(source.name)': \(error)")

            try? await databaseManager.updateDataSourceSyncState(
                sourceId: source.id,
                lastSyncedAt: source.lastSyncedAt,
                lastSyncError: error.localizedDescription,
                userId: source.userId,
                serverId: source.serverId
            )

            await MainActor.run {
                self.loadDataSources()
                if showNotifications {
                    NotificationManager.shared.addMessage(.error, "Failed to sync Emby source '\(source.name)'.")
                }
            }
        }
    }

    func refreshFavoriteCache(for source: LibraryDataSource) async {
        guard source.syncFavorites else {
            await MainActor.run {
                NotificationManager.shared.addMessage(.warning, "Favorites cache is disabled for '\(source.name)'.")
            }
            return
        }

        do {
            let session = try await validSession(for: source)
            let favoriteIDs = try await favoriteItemIDs(for: source, session: session, forceRefresh: true)
            try await databaseManager.applyFavoriteState(for: source.id, favoriteItemIds: favoriteIDs)

            await MainActor.run {
                self.loadDataSources()
                self.scheduleLibraryReload()
                NotificationManager.shared.addMessage(.info, "Refreshed favorites cache for '\(source.name)'.")
            }
        } catch {
            Logger.error("Failed to refresh favorites cache: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, "Failed to refresh favorites cache for '\(source.name)'.")
            }
        }
    }

    func playbackURL(for track: Track) async throws -> URL {
        guard track.sourceKind == .emby else {
            return track.url
        }

        guard let source = source(for: track) else {
            throw EmbyServiceError.invalidBaseURL
        }

        let session = try await validSession(for: source)
        return try await embyPlaybackCacheManager.playableURL(
            for: track,
            source: source,
            session: session,
            service: embyService
        )
    }

    func prefetchRemoteTracks(in queue: [Track], around currentIndex: Int) async {
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        let currentTrack = queue[currentIndex]
        guard currentTrack.sourceKind == .emby, let currentSource = source(for: currentTrack) else { return }

        let keepCount = max(0, currentSource.rollingCacheSize)
        let endIndex = min(queue.count - 1, currentIndex + keepCount)
        let tracksToKeep = Array(queue[currentIndex...endIndex]).filter { $0.sourceKind == .emby }

        do {
            let session = try await validSession(for: currentSource)
            for track in tracksToKeep.dropFirst() {
                guard let source = source(for: track) else { continue }
                await embyPlaybackCacheManager.prefetch(
                    track: track,
                    source: source,
                    session: session,
                    service: embyService
                )
            }
            await embyPlaybackCacheManager.trimCache(keeping: tracksToKeep)
        } catch {
            Logger.error("Failed to prefetch Emby tracks: \(error)")
        }
    }

    private func favoriteItemIDs(
        for source: LibraryDataSource,
        session: EmbySession,
        forceRefresh: Bool
    ) async throws -> Set<String> {
        guard source.syncFavorites else {
            return []
        }

        if !forceRefresh, favoriteCacheIsValid(source) {
            return databaseManager.favoriteCacheItemIds(for: source.id)
        }

        let favoriteIDs = try await embyService.fetchFavoriteAudioItemIDs(source: source, session: session)
        try await databaseManager.replaceFavoriteCache(for: source.id, itemIds: favoriteIDs, cachedAt: Date())
        return favoriteIDs
    }

    private func favoriteCacheIsValid(_ source: LibraryDataSource) -> Bool {
        guard let lastUpdated = source.favoritesCacheUpdatedAt else {
            return false
        }

        return Date().timeIntervalSince(lastUpdated) < TimeInterval(source.favoritesCacheTTLSeconds)
    }

    private func validSession(for source: LibraryDataSource) async throws -> EmbySession {
        if let token = KeychainManager.retrieve(key: KeychainManager.Keys.embyAccessTokenKey(for: source.id)),
           let userId = source.userId,
           !token.isEmpty,
           !userId.isEmpty {
            return EmbySession(accessToken: token, userId: userId, serverId: source.serverId)
        }

        let password = passwordForDataSource(source)
        guard !password.isEmpty else {
            throw EmbyServiceError.invalidCredentials
        }

        let session = try await embyService.authenticate(source: source, password: password)
        KeychainManager.save(key: KeychainManager.Keys.embyAccessTokenKey(for: source.id), value: session.accessToken)
        try await databaseManager.updateDataSourceSyncState(
            sourceId: source.id,
            lastSyncedAt: source.lastSyncedAt,
            lastSyncError: nil,
            userId: session.userId,
            serverId: session.serverId
        )
        return session
    }

    private func source(for track: Track) -> LibraryDataSource? {
        guard let sourceId = track.sourceId else { return nil }
        return dataSources.first { $0.id.uuidString == sourceId }
    }

    private func buildTrack(
        from item: EmbyAudioItem,
        source: LibraryDataSource,
        favoriteIDs: Set<String>
    ) -> FullTrack? {
        guard let itemId = item.id else { return nil }

        let url = TrackLocator.makeEmbyURL(sourceId: source.id, itemId: itemId)
        var track = FullTrack(url: url)
        track.sourceId = source.id.uuidString
        track.sourceKind = source.kind
        track.remoteItemId = itemId
        track.title = item.name ?? item.fileName?.deletingPathExtension ?? "Unknown Title"

        let artists = item.artists ?? item.artistItems?.compactMap(\.name)
        track.artist = artists?.joined(separator: "; ") ?? item.albumArtist ?? "Unknown Artist"
        track.album = item.album ?? "Unknown Album"
        track.albumArtist = item.albumArtist ?? item.albumArtists?.first?.name
        track.composer = item.composers?.compactMap(\.name).joined(separator: "; ") ?? "Unknown Composer"
        let genres = item.genres ?? item.genreItems?.compactMap(\.name)
        track.genre = genres?.joined(separator: "; ") ?? "Unknown Genre"
        track.year = item.productionYear.map(String.init) ?? "Unknown Year"
        track.duration = Double(item.runTimeTicks ?? item.mediaSources?.first?.runTimeTicks ?? 0) / 10_000_000.0
        track.format = resolvedFormat(from: item)
        track.fileSize = item.size ?? item.mediaSources?.first?.size
        track.dateAdded = item.dateCreated
        track.dateModified = item.dateModified
        track.isFavorite = source.syncFavorites ? favoriteIDs.contains(itemId) : (item.userData?.isFavorite ?? false)
        track.playCount = item.userData?.playCount ?? 0
        track.lastPlayedDate = item.userData?.lastPlayedDate
        track.trackNumber = item.indexNumber
        track.discNumber = item.parentIndexNumber
        track.mediaType = item.mediaType
        track.bitrate = item.bitrate ?? item.mediaSources?.first?.bitrate
        track.sampleRate = item.mediaStreams?.first(where: \.isAudio)?.sampleRate
            ?? item.mediaSources?.first?.mediaStreams?.first(where: \.isAudio)?.sampleRate
        track.channels = item.mediaStreams?.first(where: \.isAudio)?.channels
            ?? item.mediaSources?.first?.mediaStreams?.first(where: \.isAudio)?.channels
        track.codec = item.audioCodec
            ?? item.mediaStreams?.first(where: \.isAudio)?.codec
            ?? item.mediaSources?.first?.mediaStreams?.first(where: \.isAudio)?.codec
        track.bitDepth = item.mediaStreams?.first(where: \.isAudio)?.bitDepth
            ?? item.mediaSources?.first?.mediaStreams?.first(where: \.isAudio)?.bitDepth
        track.lossless = resolvedFormatIsLossless(track.format)
        track.remoteEnrichmentState = remoteEnrichmentState(for: item, track: track)
        track.isMetadataLoaded = true
        return track
    }

    private func resolvedFormat(from item: EmbyAudioItem) -> String {
        if let container = item.container, !container.isEmpty {
            return container.lowercased()
        }

        if let container = item.mediaSources?.first?.container, !container.isEmpty {
            return container.lowercased()
        }

        if let fileName = item.fileName, !fileName.isEmpty {
            return URL(fileURLWithPath: fileName).pathExtension.lowercased()
        }

        return "mp3"
    }

    private func resolvedFormatIsLossless(_ format: String) -> Bool {
        let normalized = format.lowercased()
        return ["flac", "alac", "wav", "aiff", "ape", "wv", "tta"].contains(normalized)
    }

    private func remoteEnrichmentState(for item: EmbyAudioItem, track: FullTrack) -> RemoteTrackEnrichmentState {
        if track.artist.isEmpty || track.artist == "Unknown Artist" {
            return .pending
        }

        if track.album.isEmpty || track.album == "Unknown Album" {
            return .pending
        }

        if track.composer.isEmpty || track.composer == "Unknown Composer" {
            return .pending
        }

        if track.genre.isEmpty || track.genre == "Unknown Genre" {
            return .pending
        }

        if track.year.isEmpty || track.year == "Unknown Year" {
            return .pending
        }

        if track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .pending
        }

        if track.trackNumber == nil || track.discNumber == nil {
            return .pending
        }

        if item.hasPrimaryImage {
            return .pending
        }

        return .completed
    }

    private func fetchArtworkForEnrichmentBatch(
        source: LibraryDataSource,
        session: EmbySession,
        tracks: [FullTrack],
        detailedItemsByID: [String: EmbyAudioItem]
    ) async throws -> [String: Data] {
        let tracksByItemID = Dictionary(
            uniqueKeysWithValues: tracks.compactMap { track -> (String, FullTrack)? in
                guard let itemId = track.remoteItemId else { return nil }
                return (itemId, track)
            }
        )

        let itemsWithEmbyArtwork = detailedItemsByID.values
            .filter { $0.hasPrimaryImage }

        let maxConcurrentDownloads = DatabaseConstants.remoteArtworkDownloadConcurrency
        let items = Array(itemsWithEmbyArtwork)
        var artworkByItemID: [String: Data] = [:]
        var index = 0

        while index < items.count {
            let upperBound = min(index + maxConcurrentDownloads, items.count)
            let chunk = Array(items[index..<upperBound])

            let downloadedPairs = try await withThrowingTaskGroup(of: (String, Data?).self) { group in
                for item in chunk {
                    guard let itemId = item.id else { continue }
                    group.addTask {
                        let imageData = try await self.embyService.downloadPrimaryImageData(
                            source: source,
                            session: session,
                            itemId: itemId,
                            imageTag: item.primaryImageTag ?? item.imageTags?["Primary"]
                        )
                        return (itemId, imageData)
                    }
                }

                var pairs: [(String, Data?)] = []
                for try await pair in group {
                    pairs.append(pair)
                }
                return pairs
            }

            for (itemId, imageData) in downloadedPairs {
                if let imageData, !imageData.isEmpty {
                    artworkByItemID[itemId] = imageData
                }
            }

            index = upperBound
        }

        let fallbackItems = detailedItemsByID.values.filter { item in
            guard let itemId = item.id else { return false }
            guard artworkByItemID[itemId] == nil else { return false }

            if let track = tracksByItemID[itemId],
               track.trackArtworkData != nil {
                return false
            }

            return true
        }

        guard !fallbackItems.isEmpty else {
            return artworkByItemID
        }

        var fallbackIndex = 0
        let fallbackArray = Array(fallbackItems)

        while fallbackIndex < fallbackArray.count {
            let upperBound = min(fallbackIndex + maxConcurrentDownloads, fallbackArray.count)
            let chunk = Array(fallbackArray[fallbackIndex..<upperBound])

            let fallbackPairs = await withTaskGroup(of: (String, Data?).self) { group in
                for item in chunk {
                    guard let itemId = item.id else { continue }
                    let fallbackTrack = tracksByItemID[itemId]

                    group.addTask {
                        let imageData = await self.iTunesArtworkService.downloadArtworkData(
                            for: item,
                            fallbackTrack: fallbackTrack
                        )
                        return (itemId, imageData)
                    }
                }

                var pairs: [(String, Data?)] = []
                for await pair in group {
                    pairs.append(pair)
                }
                return pairs
            }

            for (itemId, imageData) in fallbackPairs {
                if let imageData, !imageData.isEmpty {
                    artworkByItemID[itemId] = imageData
                }
            }

            fallbackIndex = upperBound
        }

        return artworkByItemID
    }

    private func runEmbyEnrichmentLoop(
        for source: LibraryDataSource,
        totalPendingTracks: Int,
        runToken: UUID
    ) async {
        var processedTracks = 0

        do {
            let session = try await validSession(for: source)

            while !Task.isCancelled {
                let batch = await databaseManager.nextPendingRemoteEnrichmentBatch(
                    for: source.id,
                    limit: DatabaseConstants.batchSize
                )

                guard !batch.isEmpty else { break }

                let itemIDs = batch.compactMap(\.remoteItemId)
                let detailedItems = try await embyService.fetchAudioItemsByIDs(
                    source: source,
                    session: session,
                    itemIDs: itemIDs
                )
                let detailedItemsByID: [String: EmbyAudioItem] = Dictionary(
                    uniqueKeysWithValues: detailedItems.compactMap { item -> (String, EmbyAudioItem)? in
                        guard let itemId = item.id else { return nil }
                        return (itemId, item)
                    }
                )
                let artworkByItemID = try await fetchArtworkForEnrichmentBatch(
                    source: source,
                    session: session,
                    tracks: batch,
                    detailedItemsByID: detailedItemsByID
                )

                try await databaseManager.applyEmbyTrackEnrichment(
                    for: source.id,
                    tracks: batch,
                    detailedItemsByID: detailedItemsByID,
                    artworkByItemID: artworkByItemID
                )

                processedTracks += batch.count

                await updateEmbyEnrichmentProgress(
                    for: source.id,
                    runToken: runToken,
                    sourceName: source.name,
                    current: min(processedTracks, totalPendingTracks),
                    total: totalPendingTracks
                )

                await MainActor.run {
                    self.scheduleLibraryReload()
                    self.refreshDiscoverTracks()
                }
            }

            if !Task.isCancelled {
                try await databaseManager.cleanupOrphanedData()
                await databaseManager.detectAndMarkDuplicates()

                await MainActor.run {
                    self.scheduleLibraryReload()
                    self.refreshDiscoverTracks()
                }
            }
        } catch {
            if !Task.isCancelled {
                Logger.error("Failed to enrich Emby source '\(source.name)': \(error)")
                await MainActor.run {
                    NotificationManager.shared.addMessage(.error, "Failed to fill Emby metadata for '\(source.name)'.")
                }
            }
        }

        await finishEmbyEnrichmentTask(for: source.id, runToken: runToken)
    }

    @MainActor
    private func startEmbyEnrichmentTask(for source: LibraryDataSource) async {
        cancelEmbyEnrichmentTaskSync(for: source.id)

        let totalPendingTracks = await databaseManager.pendingRemoteEnrichmentCount(for: source.id)
        guard totalPendingTracks > 0 else {
            return
        }

        embyEnrichmentProgress[source.id] = (source.name, 0, totalPendingTracks)
        refreshEmbyEnrichmentActivity()

        let runToken = UUID()
        embyEnrichmentRunTokens[source.id] = runToken

        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runEmbyEnrichmentLoop(
                for: source,
                totalPendingTracks: totalPendingTracks,
                runToken: runToken
            )
        }
        embyEnrichmentTasks[source.id] = task
    }

    @MainActor
    private func cancelEmbyEnrichmentTask(for sourceId: UUID) {
        cancelEmbyEnrichmentTaskSync(for: sourceId)
    }

    @MainActor
    private func finishEmbyEnrichmentTask(for sourceId: UUID, runToken: UUID) {
        guard embyEnrichmentRunTokens[sourceId] == runToken else {
            return
        }

        embyEnrichmentTasks.removeValue(forKey: sourceId)
        embyEnrichmentRunTokens.removeValue(forKey: sourceId)
        embyEnrichmentProgress.removeValue(forKey: sourceId)
        refreshEmbyEnrichmentActivity()
    }

    @MainActor
    private func updateEmbyEnrichmentProgress(
        for sourceId: UUID,
        runToken: UUID,
        sourceName: String,
        current: Int,
        total: Int
    ) {
        guard embyEnrichmentRunTokens[sourceId] == runToken else {
            return
        }

        embyEnrichmentProgress[sourceId] = (sourceName, current, total)
        refreshEmbyEnrichmentActivity()
    }

    @MainActor
    private func refreshEmbyEnrichmentActivity() {
        guard !embyEnrichmentProgress.isEmpty else {
            if NotificationManager.shared.activityMessage.hasPrefix("Filling Emby metadata") {
                NotificationManager.shared.stopActivity()
            }
            return
        }

        let progressItems = Array(embyEnrichmentProgress.values)
        let totalCurrent = progressItems.reduce(0) { $0 + $1.current }
        let totalTracks = progressItems.reduce(0) { $0 + $1.total }
        let message: String

        if progressItems.count == 1, let item = progressItems.first {
            message = "Filling Emby metadata for '\(item.sourceName)'..."
        } else {
            message = "Filling Emby metadata..."
        }

        NotificationManager.shared.startActivity(message)
        NotificationManager.shared.updateActivityProgress(current: totalCurrent, total: max(totalTracks, 1))
    }

    @MainActor
    private func cancelEmbyEnrichmentTaskSync(for sourceId: UUID) {
        if let task = embyEnrichmentTasks[sourceId] {
            task.cancel()
        }
        embyEnrichmentTasks.removeValue(forKey: sourceId)
        embyEnrichmentRunTokens.removeValue(forKey: sourceId)
        embyEnrichmentProgress.removeValue(forKey: sourceId)
        refreshEmbyEnrichmentActivity()
    }
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
