import Foundation

extension LibraryManager {
    func loadDataSources() {
        dataSources = databaseManager.loadAllDataSources()
        if Thread.isMainThread {
            startRemoteAutoSyncTimer()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startRemoteAutoSyncTimer()
            }
        }
    }

    func passwordForDataSource(_ source: LibraryDataSource) -> String {
        guard let passwordKey = KeychainManager.Keys.passwordKey(for: source.id, kind: source.kind) else {
            return ""
        }
        return KeychainManager.retrieve(key: passwordKey) ?? ""
    }

    func saveRemoteSource(_ source: LibraryDataSource, password: String) async -> Bool {
        switch source.kind {
        case .emby:
            return await saveEmbySource(source, password: password)
        case .navidrome:
            return await saveNavidromeSource(source, password: password)
        case .local:
            return false
        }
    }

    func saveEmbySource(_ source: LibraryDataSource, password: String) async -> Bool {
        let existingSource = dataSources.first(where: { $0.id == source.id })
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
            if let existingSource, existingSource.kind != mutableSource.kind {
                clearStoredCredentials(for: existingSource)
            }
            KeychainManager.save(key: KeychainManager.Keys.embyPasswordKey(for: mutableSource.id), value: resolvedPassword)
            KeychainManager.save(key: KeychainManager.Keys.embyAccessTokenKey(for: mutableSource.id), value: session.accessToken)

            await MainActor.run {
                self.loadDataSources()
                NotificationManager.shared.addMessage(.info, "Saved Emby source '\(savedSourceName)'.")
            }

            let requiresFullSync =
                existingSource == nil ||
                existingSource?.kind != mutableSource.kind ||
                existingSource?.host != mutableSource.host ||
                existingSource?.port != mutableSource.port ||
                existingSource?.connectionType != mutableSource.connectionType ||
                existingSource?.username != mutableSource.username

            await syncEmbySource(
                mutableSource,
                forceFavoriteRefresh: true,
                showNotifications: existingSource == nil || requiresFullSync,
                fullSync: requiresFullSync
            )
            return true
        } catch {
            Logger.error("Failed to save Emby source: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
            }
            return false
        }
    }

    func saveNavidromeSource(_ source: LibraryDataSource, password: String) async -> Bool {
        let existingSource = dataSources.first(where: { $0.id == source.id })
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
                NotificationManager.shared.addMessage(.warning, "Please fill in the Navidrome source name, host, username, and password.")
            }
            return false
        }

        var mutableSource = source
        mutableSource.updatedAt = Date()

        do {
            let session = try await navidromeService.authenticate(source: mutableSource, password: resolvedPassword)
            mutableSource.userId = session.username
            mutableSource.serverId = session.serverVersion
            mutableSource.lastSyncError = nil
            let savedSourceName = mutableSource.name

            try await databaseManager.saveDataSource(mutableSource)
            if let existingSource, existingSource.kind != mutableSource.kind {
                clearStoredCredentials(for: existingSource)
            }
            KeychainManager.save(key: KeychainManager.Keys.navidromePasswordKey(for: mutableSource.id), value: resolvedPassword)

            await MainActor.run {
                self.loadDataSources()
                NotificationManager.shared.addMessage(.info, "Saved Navidrome source '\(savedSourceName)'.")
            }

            let requiresFullSync =
                existingSource == nil ||
                existingSource?.kind != mutableSource.kind ||
                existingSource?.host != mutableSource.host ||
                existingSource?.port != mutableSource.port ||
                existingSource?.connectionType != mutableSource.connectionType ||
                existingSource?.username != mutableSource.username

            await syncNavidromeSource(
                mutableSource,
                forceFavoriteRefresh: true,
                showNotifications: existingSource == nil || requiresFullSync,
                fullSync: true
            )
            return true
        } catch {
            Logger.error("Failed to save Navidrome source: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
            }
            return false
        }
    }

    func deleteDataSource(_ source: LibraryDataSource) async {
        do {
            if source.kind == .emby {
                await cancelEmbyEnrichmentTask(for: source.id)
            }
            try await databaseManager.deleteDataSource(source.id)
            clearStoredCredentials(for: source)

            await MainActor.run {
                self.loadDataSources()
                self.loadMusicLibrary()
                NotificationManager.shared.addMessage(.info, "Removed \(source.kind.displayName) source '\(source.name)'.")
            }
        } catch {
            Logger.error("Failed to delete data source: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, "Failed to remove \(source.kind.displayName) source '\(source.name)'.")
            }
        }
    }

    func syncRemoteSource(
        _ source: LibraryDataSource,
        forceFavoriteRefresh: Bool = false,
        showNotifications: Bool = true,
        fullSync: Bool = false
    ) async {
        switch source.kind {
        case .emby:
            await syncEmbySource(
                source,
                forceFavoriteRefresh: forceFavoriteRefresh,
                showNotifications: showNotifications,
                fullSync: fullSync
            )
        case .navidrome:
            await syncNavidromeSource(
                source,
                forceFavoriteRefresh: forceFavoriteRefresh,
                showNotifications: showNotifications,
                fullSync: fullSync
            )
        case .local:
            return
        }
    }

    func syncEmbySource(
        _ source: LibraryDataSource,
        forceFavoriteRefresh: Bool = false,
        showNotifications: Bool = true,
        fullSync: Bool = false
    ) async {
        guard beginRemoteSync(for: source.id) else {
            Logger.info("Skipping Emby sync for '\(source.name)' because a sync is already in progress")
            return
        }
        defer {
            finishRemoteSync(for: source.id)
        }

        await cancelEmbyEnrichmentTask(for: source.id)

        do {
            let session = try await validSession(for: source)
            let syncCompletedAt = Date()
            let shouldRefreshFavorites = source.syncFavorites && (
                forceFavoriteRefresh || !favoriteCacheIsValid(source)
            )
            let isFullSync = fullSync
                || source.lastSyncedAt == nil
                || shouldPerformScheduledFullSync(for: source, referenceDate: syncCompletedAt)
            let hasMetadataChanges: Bool
            if isFullSync {
                hasMetadataChanges = true
            } else {
                hasMetadataChanges = try await embyLibraryHasChanges(
                    for: source,
                    session: session,
                    since: source.lastSyncedAt
                )
            }

            if !hasMetadataChanges && !shouldRefreshFavorites {
                try await databaseManager.updateDataSourceSyncState(
                    sourceId: source.id,
                    lastSyncedAt: syncCompletedAt,
                    lastSyncError: nil,
                    userId: session.userId,
                    serverId: session.serverId
                )

                await MainActor.run {
                    self.loadDataSources()
                }
                return
            }

            async let favoriteIDsTask: Set<String>? = {
                guard shouldRefreshFavorites else { return nil }

                do {
                    return try await favoriteItemIDs(
                        for: source,
                        session: session,
                        forceRefresh: true
                    )
                } catch {
                    Logger.warning("Failed to refresh Emby favorites for '\(source.name)': \(error)")
                    return nil
                }
            }()

            if !hasMetadataChanges {
                if let favoriteIDs = await favoriteIDsTask {
                    try await databaseManager.applyFavoriteState(for: source.id, favoriteItemIds: favoriteIDs)
                }

                try await databaseManager.updateDataSourceSyncState(
                    sourceId: source.id,
                    lastSyncedAt: syncCompletedAt,
                    lastSyncError: nil,
                    userId: session.userId,
                    serverId: session.serverId
                )

                await MainActor.run {
                    self.loadDataSources()
                    self.scheduleLibraryReload(delay: 0.05)
                    self.refreshDiscoverTracks()
                }
                return
            }

            let incrementalCutoff = isFullSync ? nil : source.lastSyncedAt?.addingTimeInterval(-60)

            let pageSize = DatabaseConstants.embySyncPageSize
            var startIndex = 0
            var retainedTrackKeys = Set<String>()
            var pendingTracksForEnrichment: [Int64: FullTrack] = [:]
            var syncedTrackCount = 0
            var reportedTotalTrackCount = 0
            let activityVerb = isFullSync ? "Syncing" : "Updating"

            if showNotifications {
                await MainActor.run {
                    NotificationManager.shared.startActivity("\(activityVerb) Emby source '\(source.name)'...")
                }
            }

            while true {
                let page = try await embyService.fetchAudioItemsPage(
                    source: source,
                    session: session,
                    startIndex: startIndex,
                    limit: pageSize,
                    minDateLastSaved: incrementalCutoff
                )

                let items = page.items ?? []
                if reportedTotalTrackCount == 0 {
                    reportedTotalTrackCount = page.totalRecordCount ?? items.count
                }

                let tracks = items.compactMap { buildTrack(from: $0, source: source, favoriteIDs: []) }
                let upsertResult = try await databaseManager.upsertTracksPage(for: source, tracks: tracks)
                retainedTrackKeys.formUnion(upsertResult.retainedTrackKeys)
                for pendingTrack in upsertResult.pendingTracks {
                    guard let trackId = pendingTrack.trackId else { continue }
                    pendingTracksForEnrichment[trackId] = pendingTrack
                }
                syncedTrackCount += tracks.count
                let currentSyncedTrackCount = syncedTrackCount
                let currentReportedTotalTrackCount = max(reportedTotalTrackCount, currentSyncedTrackCount)

                await MainActor.run {
                    self.scheduleLibraryReload(delay: 0.05)
                    if showNotifications {
                        let progressDetailPrefix = isFullSync ? "Indexed" : "Updated"
                        NotificationManager.shared.updateActivityProgress(
                            current: currentSyncedTrackCount,
                            total: currentReportedTotalTrackCount,
                            detail: "\(progressDetailPrefix) \(currentSyncedTrackCount) tracks from '\(source.name)'"
                        )
                    }
                }

                guard items.count == pageSize else { break }
                startIndex += pageSize
            }

            if isFullSync {
                try await databaseManager.deleteRemoteTracks(for: source, retaining: retainedTrackKeys)
                recordScheduledFullSync(for: source.id, completedAt: syncCompletedAt)
            }

            if let favoriteIDs = await favoriteIDsTask {
                try await databaseManager.applyFavoriteState(for: source.id, favoriteItemIds: favoriteIDs)
            }

            try await databaseManager.updateDataSourceSyncState(
                sourceId: source.id,
                lastSyncedAt: syncCompletedAt,
                lastSyncError: nil,
                userId: session.userId,
                serverId: session.serverId
            )
            let finalSyncedTrackCount = syncedTrackCount

            await MainActor.run {
                self.loadDataSources()
                self.loadMusicLibrary()
                self.refreshDiscoverTracks()
                if showNotifications {
                    NotificationManager.shared.stopActivity()
                    let statusVerb = isFullSync ? "Synced" : "Updated"
                    NotificationManager.shared.addMessage(.info, "\(statusVerb) Emby source '\(source.name)' (\(finalSyncedTrackCount) tracks).")
                }
            }

            await startEmbyEnrichmentTask(
                for: source,
                seededTracks: Array(pendingTracksForEnrichment.values)
            )
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
                    NotificationManager.shared.stopActivity()
                    NotificationManager.shared.addMessage(.error, "Failed to sync Emby source '\(source.name)'.")
                }
            }
        }
    }

    func syncNavidromeSource(
        _ source: LibraryDataSource,
        forceFavoriteRefresh: Bool = false,
        showNotifications: Bool = true,
        fullSync: Bool = false
    ) async {
        guard beginRemoteSync(for: source.id) else {
            Logger.info("Skipping Navidrome sync for '\(source.name)' because a sync is already in progress")
            return
        }
        defer {
            finishRemoteSync(for: source.id)
        }

        do {
            let session = try await validNavidromeSession(for: source)
            let syncCompletedAt = Date()
            let shouldRefreshFavorites = source.syncFavorites && (
                forceFavoriteRefresh || !favoriteCacheIsValid(source)
            )
            let hasMetadataChanges: Bool
            if fullSync || source.lastSyncedAt == nil {
                hasMetadataChanges = true
            } else {
                hasMetadataChanges = try await navidromeLibraryHasChanges(
                    for: source,
                    session: session,
                    since: source.lastSyncedAt
                )
            }

            if !hasMetadataChanges && !shouldRefreshFavorites {
                try await databaseManager.updateDataSourceSyncState(
                    sourceId: source.id,
                    lastSyncedAt: syncCompletedAt,
                    lastSyncError: nil,
                    userId: session.username,
                    serverId: session.serverVersion
                )

                await MainActor.run {
                    self.loadDataSources()
                }
                return
            }

            async let favoriteIDsTask: Set<String>? = {
                guard shouldRefreshFavorites else { return nil }

                do {
                    return try await navidromeFavoriteItemIDs(
                        for: source,
                        session: session,
                        forceRefresh: true
                    )
                } catch {
                    Logger.warning("Failed to refresh Navidrome favorites for '\(source.name)': \(error)")
                    return nil
                }
            }()

            if !hasMetadataChanges {
                if let favoriteIDs = await favoriteIDsTask {
                    try await databaseManager.applyFavoriteState(for: source.id, favoriteItemIds: favoriteIDs)
                }

                try await databaseManager.updateDataSourceSyncState(
                    sourceId: source.id,
                    lastSyncedAt: syncCompletedAt,
                    lastSyncError: nil,
                    userId: session.username,
                    serverId: session.serverVersion
                )

                await MainActor.run {
                    self.loadDataSources()
                    self.scheduleLibraryReload(delay: 0.05)
                    self.refreshDiscoverTracks()
                }
                return
            }

            let pageSize = DatabaseConstants.embySyncPageSize
            var offset = 0
            var retainedTrackKeys = Set<String>()
            var syncedTrackCount = 0

            if showNotifications {
                await MainActor.run {
                    NotificationManager.shared.startActivity("Updating Navidrome source '\(source.name)'...")
                }
            }

            while true {
                let albumSummaries = try await navidromeService.fetchAlbumListPage(
                    source: source,
                    session: session,
                    offset: offset,
                    size: pageSize
                )

                guard !albumSummaries.isEmpty else { break }

                let pageEntries = await fetchNavidromeAlbumsForPage(
                    source: source,
                    session: session,
                    albumSummaries: albumSummaries
                )
                let tracks = pageEntries.flatMap { entry in
                    buildTracks(
                        from: entry.album,
                        source: source,
                        favoriteIDs: [],
                        artworkData: entry.artworkData
                    )
                }

                let upsertResult = try await databaseManager.upsertTracksPage(for: source, tracks: tracks)
                retainedTrackKeys.formUnion(upsertResult.retainedTrackKeys)
                syncedTrackCount += tracks.count
                let currentSyncedTrackCount = syncedTrackCount

                await MainActor.run {
                    self.scheduleLibraryReload(delay: 0.05)
                    if showNotifications {
                        NotificationManager.shared.updateActivityProgress(
                            current: currentSyncedTrackCount,
                            total: max(currentSyncedTrackCount, 1),
                            detail: "Indexed \(currentSyncedTrackCount) tracks from '\(source.name)'"
                        )
                    }
                }

                guard albumSummaries.count == pageSize else { break }
                offset += pageSize
            }

            try await databaseManager.deleteRemoteTracks(for: source, retaining: retainedTrackKeys)

            if let favoriteIDs = await favoriteIDsTask {
                try await databaseManager.applyFavoriteState(for: source.id, favoriteItemIds: favoriteIDs)
            }

            try await databaseManager.updateDataSourceSyncState(
                sourceId: source.id,
                lastSyncedAt: syncCompletedAt,
                lastSyncError: nil,
                userId: session.username,
                serverId: session.serverVersion
            )
            let finalSyncedTrackCount = syncedTrackCount

            await MainActor.run {
                self.loadDataSources()
                self.loadMusicLibrary()
                self.refreshDiscoverTracks()
                if showNotifications {
                    NotificationManager.shared.stopActivity()
                    NotificationManager.shared.addMessage(.info, "Updated Navidrome source '\(source.name)' (\(finalSyncedTrackCount) tracks).")
                }
            }
        } catch {
            Logger.error("Failed to sync Navidrome source '\(source.name)': \(error)")

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
                    NotificationManager.shared.stopActivity()
                    NotificationManager.shared.addMessage(.error, "Failed to sync Navidrome source '\(source.name)'.")
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
            let favoriteIDs: Set<String>
            switch source.kind {
            case .emby:
                let session = try await validSession(for: source)
                favoriteIDs = try await favoriteItemIDs(for: source, session: session, forceRefresh: true)
            case .navidrome:
                let session = try await validNavidromeSession(for: source)
                favoriteIDs = try await navidromeFavoriteItemIDs(for: source, session: session, forceRefresh: true)
            case .local:
                return
            }
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

    func rebuildRemoteSourceIndex(for source: LibraryDataSource) async {
        await MainActor.run {
            NotificationManager.shared.startActivity("Rebuilding \(source.kind.displayName) index for '\(source.name)'...")
        }

        await syncRemoteSource(
            source,
            forceFavoriteRefresh: true,
            showNotifications: true,
            fullSync: true
        )

        await MainActor.run {
            if NotificationManager.shared.activityMessage == "Rebuilding \(source.kind.displayName) index for '\(source.name)'..." {
                NotificationManager.shared.stopActivity()
            }
        }
    }

    func rebuildEmbySourceIndex(for source: LibraryDataSource) async {
        await rebuildRemoteSourceIndex(for: source)
    }

    func remoteSource(for track: Track) -> LibraryDataSource? {
        source(for: track)
    }

    func shouldSyncFavoriteStateRemotely(for track: Track) -> Bool {
        guard let source = source(for: track) else { return false }
        return source.kind != .local && source.syncFavorites
    }

    func syncRemoteFavoriteStatus(for track: Track, isFavorite: Bool) async throws {
        guard let source = source(for: track),
              let itemId = track.remoteItemId else {
            return
        }

        switch source.kind {
        case .emby:
            let session = try await validSession(for: source)
            try await embyService.setFavorite(
                source: source,
                session: session,
                itemId: itemId,
                isFavorite: isFavorite
            )
        case .navidrome:
            let session = try await validNavidromeSession(for: source)
            try await navidromeService.setFavorite(
                source: source,
                session: session,
                itemId: itemId,
                isFavorite: isFavorite
            )
        case .local:
            return
        }

        if source.syncFavorites {
            try await databaseManager.updateFavoriteCache(
                for: source.id,
                itemId: itemId,
                isFavorite: isFavorite
            )
        }
    }

    func reportRemotePlayback(
        _ state: RemotePlaybackSyncState,
        phase: RemotePlaybackSyncPhase
    ) async throws {
        guard let source = source(for: state.track),
              let itemId = state.track.remoteItemId else {
            return
        }

        switch source.kind {
        case .emby:
            let session = try await validSession(for: source)
            let positionTicks = Int64(max(0, state.position) * 10_000_000)

            switch phase {
            case .started:
                try await embyService.reportPlaybackStarted(
                    source: source,
                    session: session,
                    itemId: itemId,
                    positionTicks: positionTicks,
                    isPaused: state.isPaused,
                    playSessionId: state.playSessionId
                )
            case .progress(let eventName):
                try await embyService.reportPlaybackProgress(
                    source: source,
                    session: session,
                    itemId: itemId,
                    positionTicks: positionTicks,
                    isPaused: state.isPaused,
                    playSessionId: state.playSessionId,
                    eventName: eventName.rawValue
                )
            case .stopped(let finished):
                try await embyService.reportPlaybackStopped(
                    source: source,
                    session: session,
                    itemId: itemId,
                    positionTicks: positionTicks,
                    playSessionId: state.playSessionId
                )
                if finished {
                    try await embyService.markPlayed(
                        source: source,
                        session: session,
                        itemId: itemId
                    )
                }
            }
        case .navidrome:
            let session = try await validNavidromeSession(for: source)
            let queueItemIds = state.queueItemIds.isEmpty ? [itemId] : state.queueItemIds
            let positionMillis = Int64(max(0, state.position) * 1000)

            switch phase {
            case .started:
                try await navidromeService.scrobble(
                    source: source,
                    session: session,
                    itemId: itemId,
                    submission: false,
                    time: state.startedAt
                )
                try await navidromeService.savePlayQueue(
                    source: source,
                    session: session,
                    queueItemIds: queueItemIds,
                    currentItemId: itemId,
                    positionMillis: positionMillis
                )
            case .progress:
                try await navidromeService.savePlayQueue(
                    source: source,
                    session: session,
                    queueItemIds: queueItemIds,
                    currentItemId: state.currentItemId ?? itemId,
                    positionMillis: positionMillis
                )
            case .stopped(let finished):
                if finished {
                    try await navidromeService.scrobble(
                        source: source,
                        session: session,
                        itemId: itemId,
                        submission: true,
                        time: state.startedAt
                    )
                } else {
                    try await navidromeService.savePlayQueue(
                        source: source,
                        session: session,
                        queueItemIds: queueItemIds,
                        currentItemId: state.currentItemId ?? itemId,
                        positionMillis: positionMillis
                    )
                }
            }
        case .local:
            return
        }
    }

    func fetchRemotePlaybackState(
        for state: RemotePlaybackSyncState
    ) async throws -> RemotePlaybackServerState? {
        guard let source = source(for: state.track),
              let itemId = state.track.remoteItemId else {
            return nil
        }

        switch source.kind {
        case .emby:
            let session = try await validSession(for: source)
            let item = try await embyService.fetchAudioItem(
                source: source,
                session: session,
                itemId: itemId
            )
            let positionTicks = item.userData?.playbackPositionTicks ?? 0
            return RemotePlaybackServerState(
                currentItemId: itemId,
                position: Double(positionTicks) / 10_000_000.0,
                lastUpdatedAt: item.userData?.lastPlayedDate
            )
        case .navidrome:
            let session = try await validNavidromeSession(for: source)
            guard let playQueue = try await navidromeService.fetchPlayQueue(
                source: source,
                session: session
            ) else {
                return nil
            }
            return RemotePlaybackServerState(
                currentItemId: playQueue.current,
                position: Double(playQueue.position ?? 0) / 1000.0,
                lastUpdatedAt: playQueue.changed
            )
        case .local:
            return nil
        }
    }

    func playbackURL(for track: Track) async throws -> URL {
        guard track.isRemote else {
            return track.url
        }

        guard let source = source(for: track) else {
            switch track.sourceKind {
            case .emby:
                throw EmbyServiceError.invalidBaseURL
            case .navidrome:
                throw NavidromeServiceError.invalidBaseURL
            case .local:
                return track.url
            }
        }

        switch source.kind {
        case .emby:
            let session = try await validSession(for: source)
            return try await remotePlaybackCacheManager.playableURL(
                for: track,
                provider: embyPlaybackProvider(source: source, session: session)
            )
        case .navidrome:
            let session = try await validNavidromeSession(for: source)
            return try await remotePlaybackCacheManager.playableURL(
                for: track,
                provider: navidromePlaybackProvider(source: source, session: session)
            )
        case .local:
            return track.url
        }
    }

    func prefetchRemoteTracks(in queue: [Track], around currentIndex: Int) async {
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        let currentTrack = queue[currentIndex]
        guard currentTrack.isRemote, let currentSource = source(for: currentTrack) else { return }

        let keepRadius = max(0, currentSource.rollingCacheSize)
        let startIndex = max(0, currentIndex - keepRadius)
        let endIndex = min(queue.count - 1, currentIndex + keepRadius)
        let tracksToKeep = Array(queue[startIndex...endIndex]).filter { $0.sourceKind == currentSource.kind }

        switch currentSource.kind {
        case .emby:
            do {
                var sessionsBySourceID: [UUID: EmbySession] = [
                    currentSource.id: try await validSession(for: currentSource)
                ]

                for track in tracksToKeep where track.id != currentTrack.id {
                    guard let source = source(for: track) else { continue }
                    let session: EmbySession
                    if let existingSession = sessionsBySourceID[source.id] {
                        session = existingSession
                    } else {
                        session = try await validSession(for: source)
                        sessionsBySourceID[source.id] = session
                    }

                    await remotePlaybackCacheManager.prefetch(
                        track: track,
                        provider: embyPlaybackProvider(source: source, session: session)
                    )
                }
                await remotePlaybackCacheManager.trimCache(keeping: tracksToKeep)
            } catch {
                Logger.error("Failed to prefetch Emby tracks: \(error)")
            }
        case .navidrome:
            do {
                var sessionsBySourceID: [UUID: NavidromeSession] = [
                    currentSource.id: try await validNavidromeSession(for: currentSource)
                ]

                for track in tracksToKeep where track.id != currentTrack.id {
                    guard let source = source(for: track) else { continue }
                    let session: NavidromeSession
                    if let existingSession = sessionsBySourceID[source.id] {
                        session = existingSession
                    } else {
                        session = try await validNavidromeSession(for: source)
                        sessionsBySourceID[source.id] = session
                    }

                    await remotePlaybackCacheManager.prefetch(
                        track: track,
                        provider: navidromePlaybackProvider(source: source, session: session)
                    )
                }
                await remotePlaybackCacheManager.trimCache(keeping: tracksToKeep)
            } catch {
                Logger.error("Failed to prefetch Navidrome tracks: \(error)")
            }
        case .local:
            return
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

    private func navidromeFavoriteItemIDs(
        for source: LibraryDataSource,
        session: NavidromeSession,
        forceRefresh: Bool
    ) async throws -> Set<String> {
        guard source.syncFavorites else {
            return []
        }

        if !forceRefresh, favoriteCacheIsValid(source) {
            return databaseManager.favoriteCacheItemIds(for: source.id)
        }

        let favoriteIDs = try await navidromeService.fetchFavoriteAudioItemIDs(source: source, session: session)
        try await databaseManager.replaceFavoriteCache(for: source.id, itemIds: favoriteIDs, cachedAt: Date())
        return favoriteIDs
    }

    private func embyLibraryHasChanges(
        for source: LibraryDataSource,
        session: EmbySession,
        since lastSyncedAt: Date?
    ) async throws -> Bool {
        guard let lastSyncedAt else { return true }

        let probe = try await embyService.fetchAudioItemsPage(
            source: source,
            session: session,
            startIndex: 0,
            limit: 1,
            minDateLastSaved: lastSyncedAt.addingTimeInterval(-60)
        )
        return !(probe.items ?? []).isEmpty
    }

    private func navidromeLibraryHasChanges(
        for source: LibraryDataSource,
        session: NavidromeSession,
        since lastSyncedAt: Date?
    ) async throws -> Bool {
        guard let lastSyncedAt else { return true }

        guard let scanStatus = try await navidromeService.fetchScanStatus(
            source: source,
            session: session
        ) else {
            return true
        }

        if scanStatus.scanning == true {
            return true
        }

        guard let lastScan = scanStatus.lastScan else {
            return true
        }

        return lastScan > lastSyncedAt
    }

    private func shouldPerformScheduledFullSync(
        for source: LibraryDataSource,
        referenceDate: Date = Date()
    ) -> Bool {
        guard source.kind == .emby else { return false }

        guard let lastFullSyncAt = userDefaults.object(forKey: scheduledFullSyncKey(for: source.id)) as? Date else {
            return true
        }

        return referenceDate.timeIntervalSince(lastFullSyncAt) >= TimeConstants.twentyFourHours
    }

    private func recordScheduledFullSync(for sourceId: UUID, completedAt: Date) {
        userDefaults.set(completedAt, forKey: scheduledFullSyncKey(for: sourceId))
    }

    private func scheduledFullSyncKey(for sourceId: UUID) -> String {
        "remoteFullSyncAt.\(sourceId.uuidString)"
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

    private func validNavidromeSession(for source: LibraryDataSource) async throws -> NavidromeSession {
        let password = passwordForDataSource(source)
        guard !password.isEmpty else {
            throw NavidromeServiceError.invalidCredentials
        }

        return NavidromeSession(
            username: source.username,
            password: password,
            serverVersion: source.serverId
        )
    }

    private func clearStoredCredentials(for source: LibraryDataSource) {
        if let passwordKey = KeychainManager.Keys.passwordKey(for: source.id, kind: source.kind) {
            KeychainManager.delete(key: passwordKey)
        }

        if let accessTokenKey = KeychainManager.Keys.accessTokenKey(for: source.id, kind: source.kind) {
            KeychainManager.delete(key: accessTokenKey)
        }

        userDefaults.removeObject(forKey: scheduledFullSyncKey(for: source.id))
    }

    private func embyPlaybackProvider(source: LibraryDataSource, session: EmbySession) -> RemotePlaybackProvider {
        let service = embyService
        return RemotePlaybackProvider(
            playbackURL: { track in
                try await service.makePlaybackURL(source: source, session: session, track: track)
            },
            downloadAudio: { track, destinationURL, progressHandler in
                try await service.downloadAudio(
                    source: source,
                    session: session,
                    track: track,
                    destinationURL: destinationURL,
                    progressHandler: progressHandler
                )
            }
        )
    }

    private func navidromePlaybackProvider(source: LibraryDataSource, session: NavidromeSession) -> RemotePlaybackProvider {
        let service = navidromeService
        return RemotePlaybackProvider(
            playbackURL: { track in
                try await service.makePlaybackURL(source: source, session: session, track: track)
            },
            downloadAudio: { track, destinationURL, progressHandler in
                try await service.downloadAudio(
                    source: source,
                    session: session,
                    track: track,
                    destinationURL: destinationURL,
                    progressHandler: progressHandler
                )
            }
        )
    }

    private func fetchNavidromeAlbumsForPage(
        source: LibraryDataSource,
        session: NavidromeSession,
        albumSummaries: [NavidromeAlbumSummary]
    ) async -> [NavidromeAlbumSyncEntry] {
        let chunkSize = max(1, DatabaseConstants.remoteArtworkDownloadConcurrency)
        let service = navidromeService
        var entries: [NavidromeAlbumSyncEntry] = []

        for chunk in albumSummaries.chunked(into: chunkSize) {
            let batch = await withTaskGroup(of: NavidromeAlbumSyncEntry?.self) { group in
                for summary in chunk {
                    group.addTask {
                        do {
                            let album = try await service.fetchAlbum(
                                source: source,
                                session: session,
                                albumId: summary.id
                            )

                            let coverArtId = [
                                album.coverArt,
                                summary.coverArt,
                                album.song?.first?.coverArt
                            ]
                                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .first { !$0.isEmpty }
                            let artworkData: Data?
                            if let coverArtId {
                                do {
                                    artworkData = try await service.downloadCoverArtData(
                                        source: source,
                                        session: session,
                                        coverArtId: coverArtId
                                    )
                                } catch {
                                    Logger.warning("Failed to download Navidrome artwork for album \(summary.id): \(error)")
                                    artworkData = nil
                                }
                            } else {
                                artworkData = nil
                            }

                            return NavidromeAlbumSyncEntry(album: album, artworkData: artworkData)
                        } catch {
                            Logger.warning("Failed to fetch Navidrome album \(summary.id): \(error)")
                            return nil
                        }
                    }
                }

                var resolvedEntries: [NavidromeAlbumSyncEntry] = []
                for await entry in group {
                    if let entry {
                        resolvedEntries.append(entry)
                    }
                }
                return resolvedEntries
            }

            entries.append(contentsOf: batch)
        }

        return entries
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
        track.year = MetadataYearResolver.resolvedYear(
            primaryYear: item.productionYear.map(String.init),
            releaseDate: item.premiereDate
        ) ?? "Unknown Year"
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

    private func buildTracks(
        from album: NavidromeAlbum,
        source: LibraryDataSource,
        favoriteIDs: Set<String>,
        artworkData: Data?
    ) -> [FullTrack] {
        let songs = album.song ?? []
        let totalTracks = songs.isEmpty ? nil : songs.count
        let discNumbers = Set(songs.compactMap(\.discNumber))
        let totalDiscs = discNumbers.isEmpty ? nil : discNumbers.count

        return songs.map { song in
            let url = TrackLocator.makeRemoteURL(kind: source.kind, sourceId: source.id, itemId: song.id)
            var track = FullTrack(url: url)
            track.sourceId = source.id.uuidString
            track.sourceKind = source.kind
            track.remoteItemId = song.id
            track.title = firstNonEmptyString([
                song.title,
                song.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ]) ?? "Unknown Title"
            track.artist = firstNonEmptyString([
                song.displayArtist,
                joinedNames(song.artists),
                song.artist,
                album.artist
            ]) ?? "Unknown Artist"
            track.album = firstNonEmptyString([song.album, album.name]) ?? "Unknown Album"
            track.albumArtist = firstNonEmptyString([
                song.displayAlbumArtist,
                song.albumArtists?.compactMap(\.name).first,
                album.artist
            ])
            track.composer = firstNonEmptyString([song.displayComposer]) ?? "Unknown Composer"
            track.genre = firstNonEmptyString([
                song.genre,
                joinedNames(song.genres),
                album.genre,
                joinedNames(album.genres)
            ]) ?? "Unknown Genre"
            track.year = MetadataYearResolver.resolvedYear(
                primaryYear: (song.year ?? album.year).map(String.init),
                releaseDate: nil
            ) ?? "Unknown Year"
            track.duration = song.duration ?? 0
            track.format = resolvedFormat(from: song)
            track.fileSize = song.size
            track.dateAdded = song.created ?? album.created
            track.isFavorite = source.syncFavorites ? favoriteIDs.contains(song.id) : (song.starred != nil)
            track.playCount = song.playCount ?? 0
            track.trackNumber = song.track
            track.totalTracks = totalTracks
            track.discNumber = song.discNumber
            track.totalDiscs = totalDiscs
            track.rating = (song.userRating ?? 0) > 0 ? song.userRating : nil
            track.bpm = (song.bpm ?? 0) > 0 ? song.bpm : nil
            track.mediaType = song.mediaType
            track.bitrate = song.bitRate
            track.sampleRate = song.samplingRate
            track.channels = song.channelCount
            track.bitDepth = (song.bitDepth ?? 0) > 0 ? song.bitDepth : nil
            track.codec = resolvedCodec(from: song)
            track.lossless = resolvedFormatIsLossless(track.format)
            track.albumArtworkData = artworkData
            track.remoteEnrichmentState = .completed
            track.isMetadataLoaded = true
            return track
        }
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

    private func resolvedFormat(from song: NavidromeSong) -> String {
        if let suffix = song.suffix?.trimmingCharacters(in: .whitespacesAndNewlines), !suffix.isEmpty {
            return suffix.lowercased()
        }

        if let contentType = song.contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
           let codec = contentType.components(separatedBy: "/").last,
           !codec.isEmpty {
            return codec.lowercased()
        }

        if let path = song.path, !path.isEmpty {
            return URL(fileURLWithPath: path).pathExtension.lowercased()
        }

        return "mp3"
    }

    private func resolvedCodec(from song: NavidromeSong) -> String? {
        if let contentType = song.contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
           let codec = contentType.components(separatedBy: "/").last,
           !codec.isEmpty {
            return codec.lowercased()
        }

        let format = resolvedFormat(from: song)
        return format.isEmpty ? nil : format
    }

    private func firstNonEmptyString(_ candidates: [String?]) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func joinedNames(_ values: [NavidromeNamedValue]?) -> String? {
        let names = values?
            .compactMap(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let names, !names.isEmpty else {
            return nil
        }

        return names.joined(separator: "; ")
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

            let downloadedPairs = await withTaskGroup(of: (String, Data?).self) { group in
                for item in chunk {
                    guard let itemId = item.id else { continue }
                    group.addTask {
                        do {
                            let imageData = try await self.embyService.downloadPrimaryImageData(
                                source: source,
                                session: session,
                                itemId: itemId,
                                imageTag: item.primaryImageTag ?? item.imageTags?["Primary"]
                            )
                            return (itemId, imageData)
                        } catch {
                            Logger.warning("Failed to download Emby artwork for item \(itemId): \(error)")
                            return (itemId, nil)
                        }
                    }
                }

                var pairs: [(String, Data?)] = []
                for await pair in group {
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

    private func runEmbyEnrichmentLoop(
        for source: LibraryDataSource,
        seededTracks: [FullTrack],
        runToken: UUID
    ) async {
        let pendingTracks = seededTracks.filter { $0.remoteEnrichmentState == .pending }
        guard !pendingTracks.isEmpty else {
            await finishEmbyEnrichmentTask(for: source.id, runToken: runToken)
            return
        }

        var processedTracks = 0
        var nextBatchStartIndex = 0

        do {
            let session = try await validSession(for: source)

            while !Task.isCancelled, nextBatchStartIndex < pendingTracks.count {
                let upperBound = min(nextBatchStartIndex + DatabaseConstants.batchSize, pendingTracks.count)
                let batch = Array(pendingTracks[nextBatchStartIndex..<upperBound])
                nextBatchStartIndex = upperBound

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
                    current: min(processedTracks, pendingTracks.count),
                    total: pendingTracks.count
                )
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
    private func startEmbyEnrichmentTask(for source: LibraryDataSource, seededTracks: [FullTrack]? = nil) async {
        cancelEmbyEnrichmentTaskSync(for: source.id)

        let seededPendingTracks = seededTracks?.filter { $0.remoteEnrichmentState == .pending } ?? []
        let totalPendingTracks = seededTracks == nil
            ? await databaseManager.pendingRemoteEnrichmentCount(for: source.id)
            : seededPendingTracks.count
        guard totalPendingTracks > 0 else {
            return
        }

        embyEnrichmentProgress[source.id] = (source.name, 0, totalPendingTracks)
        refreshEmbyEnrichmentActivity()

        let runToken = UUID()
        embyEnrichmentRunTokens[source.id] = runToken

        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self else { return }
            if seededTracks == nil {
                await self.runEmbyEnrichmentLoop(
                    for: source,
                    totalPendingTracks: totalPendingTracks,
                    runToken: runToken
                )
            } else {
                await self.runEmbyEnrichmentLoop(
                    for: source,
                    seededTracks: seededPendingTracks,
                    runToken: runToken
                )
            }
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

private struct NavidromeAlbumSyncEntry {
    let album: NavidromeAlbum
    let artworkData: Data?
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
