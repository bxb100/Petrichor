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
            let sourceIdString = sourceId.uuidString
            let trackIds = try Track
                .filter(Track.Columns.sourceId == sourceIdString)
                .select(Track.Columns.trackId, as: Int64.self)
                .fetchAll(db)

            try deleteTracks(withRowIDs: trackIds, in: db)

            _ = try EmbyFavoriteCacheEntry
                .filter(EmbyFavoriteCacheEntry.Columns.sourceId == sourceIdString)
                .deleteAll(db)

            _ = try LibraryDataSource
                .filter(LibraryDataSource.Columns.id == sourceIdString)
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
        let upsertResult = try await upsertTracksPage(for: source, tracks: tracks)
        try await deleteRemoteTracks(for: source, retaining: upsertResult.retainedTrackKeys)
    }

    func upsertTracksPage(for source: LibraryDataSource, tracks: [FullTrack]) async throws -> RemoteTrackUpsertResult {
        try await dbQueue.write { db in
            let cache = ScanLookupCache()
            let sourceId = source.id.uuidString
            let existingTrackSnapshotsByKey = try existingRemoteTrackSnapshotsByKey(for: sourceId, in: db)

            var retainedTrackKeys = Set<String>()
            var pendingTracks: [FullTrack] = []
            var trackArtworkByTrackId: [Int64: Data] = [:]
            var albumArtworkByAlbumId: [Int64: Data] = [:]

            for track in tracks {
                var mutableTrack = track
                mutableTrack.folderId = nil
                mutableTrack.sourceId = sourceId
                mutableTrack.sourceKind = source.kind
                let trackKey = stableRemoteTrackKey(
                    sourceId: sourceId,
                    remoteItemId: mutableTrack.remoteItemId,
                    resourceLocator: mutableTrack.resourceLocator
                )
                retainedTrackKeys.insert(trackKey)

                if let existingSnapshot = existingTrackSnapshotsByKey[trackKey] {
                    mutableTrack.trackId = existingSnapshot.trackId
                    mergeRemoteSummaryTrack(&mutableTrack, with: existingSnapshot)
                }

                try upsertRemoteTrack(&mutableTrack, in: db, cache: cache)
                if mutableTrack.remoteEnrichmentState == .pending {
                    pendingTracks.append(mutableTrack)
                }
                collectArtworkCandidates(
                    from: mutableTrack,
                    trackArtworkByTrackId: &trackArtworkByTrackId,
                    albumArtworkByAlbumId: &albumArtworkByAlbumId
                )
            }

            try applyArtworkCandidates(
                trackArtworkByTrackId: trackArtworkByTrackId,
                albumArtworkByAlbumId: albumArtworkByAlbumId,
                in: db
            )
            try updateEntityStats(in: db)
            return RemoteTrackUpsertResult(retainedTrackKeys: retainedTrackKeys, pendingTracks: pendingTracks)
        }
    }

    func deleteRemoteTracks(for source: LibraryDataSource, retaining retainedTrackKeys: Set<String>) async throws {
        try await dbQueue.write { db in
            let existingTrackIdsByKey = try existingRemoteTrackIdsByKey(for: source.id.uuidString, in: db)
            let staleTrackIds = existingTrackIdsByKey.compactMap { trackKey, trackId in
                retainedTrackKeys.contains(trackKey) ? nil : trackId
            }

            try deleteTracks(withRowIDs: staleTrackIds, in: db)
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
            var trackArtworkByTrackId: [Int64: Data] = [:]
            var albumArtworkByAlbumId: [Int64: Data] = [:]

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
                    trackArtworkByTrackId[trackId] = artworkData

                    if let albumId = enrichedTrack.albumId,
                       enrichedTrack.album != "Unknown Album" {
                        albumArtworkByAlbumId[albumId] = albumArtworkByAlbumId[albumId] ?? artworkData
                    }
                }
            }

            try applyArtworkCandidates(
                trackArtworkByTrackId: trackArtworkByTrackId,
                albumArtworkByAlbumId: albumArtworkByAlbumId,
                in: db
            )
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

struct RemoteTrackUpsertResult {
    let retainedTrackKeys: Set<String>
    let pendingTracks: [FullTrack]
}

private struct RemoteTrackSyncSnapshot {
    let trackId: Int64
    let remoteEnrichmentState: RemoteTrackEnrichmentState
    let title: String
    let artist: String
    let album: String
    let composer: String
    let genre: String
    let year: String
    let duration: Double
    let format: String
    let dateAdded: Date?
    let isFavorite: Bool
    let playCount: Int
    let lastPlayedDate: Date?
    let albumArtist: String?
    let trackNumber: Int?
    let totalTracks: Int?
    let discNumber: Int?
    let totalDiscs: Int?
    let rating: Int?
    let compilation: Bool
    let releaseDate: String?
    let originalReleaseDate: String?
    let bpm: Int?
    let mediaType: String?
    let bitrate: Int?
    let sampleRate: Int?
    let channels: Int?
    let codec: String?
    let bitDepth: Int?
    let lossless: Bool?
    let fileSize: Int64?
    let dateModified: Date?
    let isDuplicate: Bool
    let primaryTrackId: Int64?
    let duplicateGroupId: String?
    let sortTitle: String?
    let sortArtist: String?
    let sortAlbum: String?
    let sortAlbumArtist: String?
    let albumId: Int64?
    let extendedMetadata: ExtendedMetadata?
}

private extension DatabaseManager {
    func existingRemoteTrackIdsByKey(for sourceId: String, in db: Database) throws -> [String: Int64] {
        let existingTrackRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, path, remote_item_id
                FROM tracks
                WHERE source_id = ?
                """,
            arguments: [sourceId]
        )

        let existingTrackKeys = existingTrackRows.compactMap { row -> (String, Int64)? in
            let trackId: Int64 = row["id"]
            let resourceLocator: String = row["path"]
            let remoteItemId: String? = row["remote_item_id"]
            return (stableRemoteTrackKey(
                sourceId: sourceId,
                remoteItemId: remoteItemId,
                resourceLocator: resourceLocator
            ), trackId)
        }

        return Dictionary(uniqueKeysWithValues: existingTrackKeys)
    }

    func existingRemoteTrackSnapshotsByKey(for sourceId: String, in db: Database) throws -> [String: RemoteTrackSyncSnapshot] {
        let existingTrackRows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    id,
                    path,
                    remote_item_id,
                    remote_enrichment_state,
                    title,
                    artist,
                    album,
                    composer,
                    genre,
                    year,
                    duration,
                    format,
                    date_added,
                    is_favorite,
                    play_count,
                    last_played_date,
                    album_artist,
                    track_number,
                    total_tracks,
                    disc_number,
                    total_discs,
                    rating,
                    compilation,
                    release_date,
                    original_release_date,
                    bpm,
                    media_type,
                    bitrate,
                    sample_rate,
                    channels,
                    codec,
                    bit_depth,
                    lossless,
                    file_size,
                    date_modified,
                    is_duplicate,
                    primary_track_id,
                    duplicate_group_id,
                    sort_title,
                    sort_artist,
                    sort_album,
                    sort_album_artist,
                    album_id,
                    extended_metadata
                FROM tracks
                WHERE source_id = ?
                """,
            arguments: [sourceId]
        )

        let existingTrackKeys = existingTrackRows.compactMap { row -> (String, RemoteTrackSyncSnapshot)? in
            let trackId: Int64 = row["id"]
            let resourceLocator: String = row["path"]
            let remoteItemId: String? = row["remote_item_id"]
            let remoteEnrichmentState = RemoteTrackEnrichmentState(rawValue: row["remote_enrichment_state"]) ?? .completed
            let snapshot = RemoteTrackSyncSnapshot(
                trackId: trackId,
                remoteEnrichmentState: remoteEnrichmentState,
                title: row["title"],
                artist: row["artist"],
                album: row["album"],
                composer: row["composer"],
                genre: row["genre"],
                year: row["year"],
                duration: row["duration"],
                format: row["format"],
                dateAdded: row["date_added"],
                isFavorite: row["is_favorite"],
                playCount: row["play_count"],
                lastPlayedDate: row["last_played_date"],
                albumArtist: row["album_artist"],
                trackNumber: row["track_number"],
                totalTracks: row["total_tracks"],
                discNumber: row["disc_number"],
                totalDiscs: row["total_discs"],
                rating: row["rating"],
                compilation: row["compilation"] ?? false,
                releaseDate: row["release_date"],
                originalReleaseDate: row["original_release_date"],
                bpm: row["bpm"],
                mediaType: row["media_type"],
                bitrate: row["bitrate"],
                sampleRate: row["sample_rate"],
                channels: row["channels"],
                codec: row["codec"],
                bitDepth: row["bit_depth"],
                lossless: row["lossless"],
                fileSize: row["file_size"],
                dateModified: row["date_modified"],
                isDuplicate: row["is_duplicate"] ?? false,
                primaryTrackId: row["primary_track_id"],
                duplicateGroupId: row["duplicate_group_id"],
                sortTitle: row["sort_title"],
                sortArtist: row["sort_artist"],
                sortAlbum: row["sort_album"],
                sortAlbumArtist: row["sort_album_artist"],
                albumId: row["album_id"],
                extendedMetadata: ExtendedMetadata.fromJSON(row["extended_metadata"])
            )
            return (stableRemoteTrackKey(
                sourceId: sourceId,
                remoteItemId: remoteItemId,
                resourceLocator: resourceLocator
            ), snapshot)
        }

        return Dictionary(uniqueKeysWithValues: existingTrackKeys)
    }

    func stableRemoteTrackKey(sourceId: String, remoteItemId: String?, resourceLocator: String) -> String {
        if let remoteItemId, !remoteItemId.isEmpty {
            return "item:\(sourceId):\(remoteItemId)"
        }

        return "path:\(resourceLocator)"
    }

    func mergeRemoteSummaryTrack(_ track: inout FullTrack, with snapshot: RemoteTrackSyncSnapshot) {
        if track.title.isEmpty || track.title == "Unknown Title" {
            track.title = snapshot.title
        }
        if track.artist.isEmpty || track.artist == "Unknown Artist" {
            track.artist = snapshot.artist
        }
        if track.album.isEmpty || track.album == "Unknown Album" {
            track.album = snapshot.album
        }
        if track.composer.isEmpty || track.composer == "Unknown Composer" {
            track.composer = snapshot.composer
        }
        if track.genre.isEmpty || track.genre == "Unknown Genre" {
            track.genre = snapshot.genre
        }
        if track.year.isEmpty || track.year == "Unknown Year" {
            track.year = snapshot.year
        }
        if track.duration <= 0 {
            track.duration = snapshot.duration
        }
        if track.format.isEmpty {
            track.format = snapshot.format
        }
        if track.dateAdded == nil {
            track.dateAdded = snapshot.dateAdded
        }
        if track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            track.albumArtist = snapshot.albumArtist
        }
        if track.trackNumber == nil {
            track.trackNumber = snapshot.trackNumber
        }
        if track.totalTracks == nil {
            track.totalTracks = snapshot.totalTracks
        }
        if track.discNumber == nil {
            track.discNumber = snapshot.discNumber
        }
        if track.totalDiscs == nil {
            track.totalDiscs = snapshot.totalDiscs
        }
        if track.rating == nil {
            track.rating = snapshot.rating
        }
        if track.releaseDate == nil {
            track.releaseDate = snapshot.releaseDate
        }
        if track.originalReleaseDate == nil {
            track.originalReleaseDate = snapshot.originalReleaseDate
        }
        if track.bpm == nil {
            track.bpm = snapshot.bpm
        }
        if track.mediaType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            track.mediaType = snapshot.mediaType
        }
        if track.bitrate == nil {
            track.bitrate = snapshot.bitrate
        }
        if track.sampleRate == nil {
            track.sampleRate = snapshot.sampleRate
        }
        if track.channels == nil {
            track.channels = snapshot.channels
        }
        if track.codec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            track.codec = snapshot.codec
        }
        if track.bitDepth == nil {
            track.bitDepth = snapshot.bitDepth
        }
        if track.lossless == nil {
            track.lossless = snapshot.lossless
        }
        if track.fileSize == nil {
            track.fileSize = snapshot.fileSize
        }
        if track.dateModified == nil {
            track.dateModified = snapshot.dateModified
        }

        track.compilation = track.compilation || snapshot.compilation
        track.isDuplicate = snapshot.isDuplicate
        track.primaryTrackId = snapshot.primaryTrackId
        track.duplicateGroupId = snapshot.duplicateGroupId
        track.sortTitle = snapshot.sortTitle
        track.sortArtist = snapshot.sortArtist
        track.sortAlbum = snapshot.sortAlbum
        track.sortAlbumArtist = snapshot.sortAlbumArtist
        track.albumId = snapshot.albumId
        if isEmptyExtendedMetadata(track.extendedMetadata) {
            track.extendedMetadata = snapshot.extendedMetadata
        }

        if snapshot.remoteEnrichmentState == .completed {
            track.remoteEnrichmentState = .completed
            return
        }

        if !hasMissingEssentialRemoteMetadata(track) {
            track.remoteEnrichmentState = .completed
        }
    }

    func hasMissingEssentialRemoteMetadata(_ track: FullTrack) -> Bool {
        if track.artist.isEmpty || track.artist == "Unknown Artist" {
            return true
        }
        if track.album.isEmpty || track.album == "Unknown Album" {
            return true
        }
        if track.composer.isEmpty || track.composer == "Unknown Composer" {
            return true
        }
        if track.genre.isEmpty || track.genre == "Unknown Genre" {
            return true
        }
        if track.year.isEmpty || track.year == "Unknown Year" {
            return true
        }
        if track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return true
        }
        if track.trackNumber == nil || track.discNumber == nil {
            return true
        }
        return false
    }

    func isEmptyExtendedMetadata(_ metadata: ExtendedMetadata?) -> Bool {
        guard let metadata else { return true }
        return metadata.toJSON() == "{}"
    }

    func upsertRemoteTrack(_ track: inout FullTrack, in db: Database, cache: ScanLookupCache) throws {
        try processTrackAlbum(&track, in: db, cache: cache)

        if let trackId = track.trackId {
            try track.update(db)

            try TrackArtist
                .filter(TrackArtist.Columns.trackId == trackId)
                .deleteAll(db)

            try TrackGenre
                .filter(TrackGenre.Columns.trackId == trackId)
                .deleteAll(db)
        } else {
            try track.insert(db)

            if track.trackId == nil {
                track.trackId = db.lastInsertedRowID
            }
        }

        guard track.trackId != nil else {
            throw DatabaseError.invalidTrackId
        }

        try processTrackArtists(track, in: db, cache: cache)
        try processTrackGenres(track, in: db, cache: cache)
    }

    func collectArtworkCandidates(
        from track: FullTrack,
        trackArtworkByTrackId: inout [Int64: Data],
        albumArtworkByAlbumId: inout [Int64: Data]
    ) {
        guard let artworkData = track.trackArtworkData ?? track.albumArtworkData,
              !artworkData.isEmpty,
              let trackId = track.trackId else {
            return
        }

        trackArtworkByTrackId[trackId] = artworkData

        if let albumId = track.albumId {
            albumArtworkByAlbumId[albumId] = albumArtworkByAlbumId[albumId] ?? artworkData
        }
    }

    func applyArtworkCandidates(
        trackArtworkByTrackId: [Int64: Data],
        albumArtworkByAlbumId: [Int64: Data],
        in db: Database
    ) throws {
        if !trackArtworkByTrackId.isEmpty {
            var artistArtworkByArtistId: [Int64: Data] = [:]

            for chunk in Array(trackArtworkByTrackId.keys).chunked(into: 400) {
                let relationships = try TrackArtist
                    .filter(chunk.contains(TrackArtist.Columns.trackId))
                    .fetchAll(db)

                for relationship in relationships where artistArtworkByArtistId[relationship.artistId] == nil {
                    guard let artworkData = trackArtworkByTrackId[relationship.trackId] else { continue }
                    artistArtworkByArtistId[relationship.artistId] = artworkData
                }
            }

            for (artistId, artworkData) in artistArtworkByArtistId {
                try updateArtistArtwork(artistId, artworkData: artworkData, in: db)
            }
        }

        for (albumId, artworkData) in albumArtworkByAlbumId {
            try updateAlbumArtwork(albumId, artworkData: artworkData, in: db)
        }
    }

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

        if let resolvedYear = MetadataYearResolver.resolvedYear(
            primaryYear: item.productionYear.map(String.init),
            releaseDate: item.premiereDate
        ),
           (track.year.isEmpty || track.year == "Unknown Year") {
            track.year = resolvedYear
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
