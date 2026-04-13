import Foundation
import GRDB

extension DatabaseManager {
    func loadAllDataSources() -> [LibraryDataSource] {
        do {
            return try dbQueue.read { db in
                try LibraryDataSource
                    .order(LibraryDataSource.Columns.createdAt)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to load data sources: \(error)")
            return []
        }
    }

    func saveDataSource(_ source: LibraryDataSource) async throws {
        var mutableSource = source
        mutableSource.updatedAt = Date()
        let sourceToSave = mutableSource

        try await dbQueue.write { db in
            try sourceToSave.save(db)
        }
    }

    func deleteDataSource(_ sourceId: UUID) async throws {
        try await dbQueue.write { db in
            _ = try LibraryDataSource
                .filter(LibraryDataSource.Columns.id == sourceId.uuidString)
                .deleteAll(db)
        }

        try await cleanupOrphanedData()
    }

    func favoriteCacheItemIds(for sourceId: UUID) -> Set<String> {
        do {
            return try dbQueue.read { db in
                let itemIds = try EmbyFavoriteCacheEntry
                    .filter(EmbyFavoriteCacheEntry.Columns.sourceId == sourceId.uuidString)
                    .select(EmbyFavoriteCacheEntry.Columns.itemId, as: String.self)
                    .fetchAll(db)
                return Set(itemIds)
            }
        } catch {
            Logger.error("Failed to load favorite cache for source \(sourceId): \(error)")
            return []
        }
    }

    func replaceFavoriteCache(for sourceId: UUID, itemIds: Set<String>, cachedAt: Date) async throws {
        try await dbQueue.write { db in
            _ = try EmbyFavoriteCacheEntry
                .filter(EmbyFavoriteCacheEntry.Columns.sourceId == sourceId.uuidString)
                .deleteAll(db)

            for itemId in itemIds {
                try EmbyFavoriteCacheEntry(sourceId: sourceId, itemId: itemId, cachedAt: cachedAt).insert(db)
            }

            _ = try LibraryDataSource
                .filter(LibraryDataSource.Columns.id == sourceId.uuidString)
                .updateAll(
                    db,
                    LibraryDataSource.Columns.favoritesCacheUpdatedAt.set(to: cachedAt),
                    LibraryDataSource.Columns.updatedAt.set(to: Date())
                )
        }
    }

    func applyFavoriteState(for sourceId: UUID, favoriteItemIds: Set<String>) async throws {
        try await dbQueue.write { db in
            _ = try Track
                .filter(Track.Columns.sourceId == sourceId.uuidString)
                .updateAll(db, Track.Columns.isFavorite.set(to: false))

            guard !favoriteItemIds.isEmpty else { return }

            for chunk in Array(favoriteItemIds).chunked(into: 400) {
                _ = try Track
                    .filter(Track.Columns.sourceId == sourceId.uuidString)
                    .filter(chunk.contains(Track.Columns.remoteItemId))
                    .updateAll(db, Track.Columns.isFavorite.set(to: true))
            }
        }
    }

    func replaceTracks(for source: LibraryDataSource, tracks: [FullTrack]) async throws {
        try await dbQueue.write { db in
            let cache = ScanLookupCache()

            _ = try Track
                .filter(Track.Columns.sourceId == source.id.uuidString)
                .deleteAll(db)

            for track in tracks {
                var mutableTrack = track
                mutableTrack.folderId = nil
                mutableTrack.sourceId = source.id.uuidString
                mutableTrack.sourceKind = source.kind

                try processTrackAlbum(&mutableTrack, in: db, cache: cache)
                try mutableTrack.insert(db)

                if mutableTrack.trackId == nil {
                    mutableTrack.trackId = db.lastInsertedRowID
                }

                try processTrackArtists(mutableTrack, in: db, cache: cache)
                try processTrackGenres(mutableTrack, in: db, cache: cache)

                if let artworkData = mutableTrack.trackArtworkData ?? mutableTrack.albumArtworkData,
                   !artworkData.isEmpty,
                   let trackId = mutableTrack.trackId {
                    let artistIds = try TrackArtist
                        .filter(TrackArtist.Columns.trackId == trackId)
                        .select(TrackArtist.Columns.artistId, as: Int64.self)
                        .distinct()
                        .fetchAll(db)

                    for artistId in artistIds {
                        try updateArtistArtwork(artistId, artworkData: artworkData, in: db)
                    }

                    if let albumId = mutableTrack.albumId {
                        try updateAlbumArtwork(albumId, artworkData: artworkData, in: db)
                    }
                }
            }

            try updateEntityStats(in: db)
        }

        try await cleanupOrphanedData()
        await detectAndMarkDuplicates()

        try await dbQueue.write { db in
            try updateEntityStats(in: db)
        }
    }

    func pendingRemoteEnrichmentCount(for sourceId: UUID) async -> Int {
        do {
            return try await dbQueue.read { db in
                try FullTrack
                    .filter(FullTrack.Columns.sourceId == sourceId.uuidString)
                    .filter(FullTrack.Columns.remoteEnrichmentState == RemoteTrackEnrichmentState.pending.rawValue)
                    .fetchCount(db)
            }
        } catch {
            Logger.error("Failed to count pending remote enrichment tracks: \(error)")
            return 0
        }
    }

    func nextPendingRemoteEnrichmentBatch(for sourceId: UUID, limit: Int) async -> [FullTrack] {
        do {
            return try await dbQueue.read { db in
                try FullTrack
                    .filter(FullTrack.Columns.sourceId == sourceId.uuidString)
                    .filter(FullTrack.Columns.remoteEnrichmentState == RemoteTrackEnrichmentState.pending.rawValue)
                    .order(FullTrack.Columns.trackId.asc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to load pending remote enrichment batch: \(error)")
            return []
        }
    }

    func applyEmbyTrackEnrichment(
        for sourceId: UUID,
        tracks: [FullTrack],
        detailedItemsByID: [String: EmbyAudioItem],
        artworkByItemID: [String: Data]
    ) async throws {
        guard !tracks.isEmpty else { return }

        try await dbQueue.write { db in
            let cache = ScanLookupCache()

            for originalTrack in tracks {
                guard let trackId = originalTrack.trackId else { continue }
                guard let itemId = originalTrack.remoteItemId,
                      let item = detailedItemsByID[itemId] else {
                    _ = try FullTrack
                        .filter(FullTrack.Columns.trackId == trackId)
                        .updateAll(
                            db,
                            FullTrack.Columns.remoteEnrichmentState.set(to: RemoteTrackEnrichmentState.completed.rawValue)
                        )
                    continue
                }

                var enrichedTrack = originalTrack
                mergeEmbyDetails(from: item, into: &enrichedTrack)
                applyRemoteArtwork(artworkByItemID[itemId], to: &enrichedTrack)
                enrichedTrack.remoteEnrichmentState = .completed

                try processTrackAlbum(&enrichedTrack, in: db, cache: cache)
                try enrichedTrack.update(db)

                try TrackArtist
                    .filter(TrackArtist.Columns.trackId == trackId)
                    .deleteAll(db)

                try TrackGenre
                    .filter(TrackGenre.Columns.trackId == trackId)
                    .deleteAll(db)

                try processTrackArtists(enrichedTrack, in: db, cache: cache)
                try processTrackGenres(enrichedTrack, in: db, cache: cache)

                if let artworkData = artworkByItemID[itemId],
                   !artworkData.isEmpty {
                    let artistIds = try TrackArtist
                        .filter(TrackArtist.Columns.trackId == trackId)
                        .select(TrackArtist.Columns.artistId, as: Int64.self)
                        .distinct()
                        .fetchAll(db)

                    for artistId in artistIds {
                        try updateArtistArtwork(artistId, artworkData: artworkData, in: db)
                    }

                    if let albumId = enrichedTrack.albumId,
                       enrichedTrack.album != "Unknown Album" {
                        try updateAlbumArtwork(albumId, artworkData: artworkData, in: db)
                    }
                }
            }

            try updateEntityStats(in: db)
        }
    }

    func updateDataSourceSyncState(
        sourceId: UUID,
        lastSyncedAt: Date?,
        lastSyncError: String?,
        userId: String?,
        serverId: String?
    ) async throws {
        try await dbQueue.write { db in
            _ = try LibraryDataSource
                .filter(LibraryDataSource.Columns.id == sourceId.uuidString)
                .updateAll(
                    db,
                    LibraryDataSource.Columns.lastSyncedAt.set(to: lastSyncedAt),
                    LibraryDataSource.Columns.lastSyncError.set(to: lastSyncError),
                    LibraryDataSource.Columns.userId.set(to: userId),
                    LibraryDataSource.Columns.serverId.set(to: serverId),
                    LibraryDataSource.Columns.updatedAt.set(to: Date())
                )
        }
    }
}

private extension DatabaseManager {
    func mergeEmbyDetails(from item: EmbyAudioItem, into track: inout FullTrack) {
        if let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           (track.title.isEmpty || track.title == "Unknown Title") {
            track.title = title
        }

        let artists = item.artists ?? item.artistItems?.compactMap(\.name)
        let mergedArtist = artists?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        if let mergedArtist,
           (track.artist.isEmpty || track.artist == "Unknown Artist") {
            track.artist = mergedArtist
        }

        if let album = item.album?.trimmingCharacters(in: .whitespacesAndNewlines),
           !album.isEmpty,
           (track.album.isEmpty || track.album == "Unknown Album") {
            track.album = album
        }

        let albumArtist = item.albumArtist ?? item.albumArtists?.compactMap(\.name).first
        if let albumArtist,
           !albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           track.albumArtist?.isEmpty != false {
            track.albumArtist = albumArtist
        }

        let composer = item.composers?
            .compactMap(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        if let composer,
           !composer.isEmpty,
           (track.composer.isEmpty || track.composer == "Unknown Composer") {
            track.composer = composer
        }

        let genre = (item.genres ?? item.genreItems?.compactMap(\.name))?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        if let genre,
           !genre.isEmpty,
           (track.genre.isEmpty || track.genre == "Unknown Genre") {
            track.genre = genre
        }

        if let productionYear = item.productionYear,
           (track.year.isEmpty || track.year == "Unknown Year") {
            track.year = String(productionYear)
        }

        if track.trackNumber == nil, let indexNumber = item.indexNumber {
            track.trackNumber = indexNumber
        }

        if track.discNumber == nil, let parentIndexNumber = item.parentIndexNumber {
            track.discNumber = parentIndexNumber
        }
    }

    func applyRemoteArtwork(_ artworkData: Data?, to track: inout FullTrack) {
        let shouldStoreTrackArtwork = track.album.isEmpty || track.album == "Unknown Album"

        if let artworkData, !artworkData.isEmpty {
            if shouldStoreTrackArtwork {
                track.trackArtworkData = artworkData
            } else {
                track.trackArtworkData = nil
            }
        } else if !shouldStoreTrackArtwork {
            track.trackArtworkData = nil
        }
    }
}
