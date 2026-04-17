import Foundation
import GRDB

struct SourceSyncBatchResult {
    let inserted: Int
    let updated: Int
}

private enum SourceVirtualFolderLayout {
    static func path(for accountID: String) -> String {
        "/.petrichor-source/\(sanitizePathComponent(accountID))"
    }

    static func name(for account: SourceAccountRecord) -> String {
        "\(account.displayName) Remote Library"
    }

    static func locator(for accountID: String, itemID: String) -> String {
        let encodedItemID = itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemID
        return "petrichor-source://\(sanitizePathComponent(accountID))/\(encodedItemID)"
    }

    static func storagePath(for accountID: String, itemID: String, filename: String) -> String {
        "/.petrichor-source/\(sanitizePathComponent(accountID))/\(sanitizePathComponent(itemID))/\(sanitizePathComponent(filename))"
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
    }
}

extension DatabaseManager {
    func ensureSourceVirtualFolder(for account: SourceAccountRecord) async throws -> Int64 {
        try await dbQueue.write { db in
            if let existingFolder = try Folder
                .filter(Folder.Columns.sourceAccountID == account.id)
                .fetchOne(db),
               let existingID = existingFolder.id {
                if existingFolder.name != SourceVirtualFolderLayout.name(for: account) {
                    var updatedFolder = existingFolder
                    updatedFolder.name = SourceVirtualFolderLayout.name(for: account)
                    updatedFolder.dateUpdated = Date()
                    try updatedFolder.update(db)
                }
                return existingID
            }

            let folder = Folder(
                virtualSourcePath: SourceVirtualFolderLayout.path(for: account.id),
                sourceAccountID: account.id,
                name: SourceVirtualFolderLayout.name(for: account)
            )
            try folder.insert(db)

            let folderID = db.lastInsertedRowID
            guard folderID > 0 else {
                throw DatabaseError.invalidFolderId
            }

            return folderID
        }
    }

    func syncSourceTracksBatch(
        account: SourceAccountRecord,
        folderID: Int64,
        snapshots: [SourceTrackSnapshot],
        syncedAt: Date
    ) async throws -> SourceSyncBatchResult {
        try await dbQueue.write { db in
            let cache = ScanLookupCache()
            var inserted = 0
            var updated = 0

            for snapshot in snapshots {
                let metadata = sourceMetadataStub(for: snapshot, accountID: account.id)

                if let existingTrack = try FullTrack
                    .filter(FullTrack.Columns.sourceID == account.id)
                    .filter(FullTrack.Columns.sourceItemID == snapshot.itemID)
                    .fetchOne(db) {
                    let updatedTrack = buildSourceTrack(
                        from: snapshot,
                        accountID: account.id,
                        folderID: folderID,
                        syncedAt: syncedAt,
                        existingTrackID: existingTrack.trackId,
                        existingLastPlayedDate: existingTrack.lastPlayedDate
                    )
                    try processUpdatedTrack(updatedTrack, metadata: metadata, in: db, cache: cache)
                    updated += 1
                } else {
                    let newTrack = buildSourceTrack(
                        from: snapshot,
                        accountID: account.id,
                        folderID: folderID,
                        syncedAt: syncedAt,
                        existingTrackID: nil,
                        existingLastPlayedDate: nil
                    )
                    try processNewTrack(newTrack, metadata: metadata, in: db, cache: cache)
                    inserted += 1
                }
            }

            return SourceSyncBatchResult(inserted: inserted, updated: updated)
        }
    }

    func pruneStaleSourceTracks(accountID: String, syncedAt: Date) async throws -> Int {
        try await dbQueue.write { db in
            try Track
                .filter(Track.Columns.sourceID == accountID)
                .filter(Track.Columns.lastSyncedAt == nil || Track.Columns.lastSyncedAt < syncedAt)
                .deleteAll(db)
        }
    }

    func finalizeSourceSync(accountID: String) async throws {
        try await dbQueue.write { db in
            try updateEntityStats(in: db)
        }

        await detectAndMarkDuplicates()
        try await cleanupOrphanedData()
        try await refreshSourceVirtualFolderTrackCount(sourceAccountID: accountID)
    }

    func refreshSourceVirtualFolderTrackCount(sourceAccountID: String) async throws {
        try await dbQueue.write { db in
            guard let folder = try Folder
                .filter(Folder.Columns.sourceAccountID == sourceAccountID)
                .fetchOne(db),
                  let folderID = folder.id else {
                return
            }

            let trackCount = try Track
                .filter(Track.Columns.folderId == folderID)
                .fetchCount(db)

            var updatedFolder = folder
            updatedFolder.trackCount = trackCount
            updatedFolder.dateUpdated = Date()
            try updatedFolder.update(db)
        }
    }

    private func buildSourceTrack(
        from snapshot: SourceTrackSnapshot,
        accountID: String,
        folderID: Int64,
        syncedAt: Date,
        existingTrackID: Int64?,
        existingLastPlayedDate: Date?
    ) -> FullTrack {
        let resolvedFilename = resolvedFilename(for: snapshot)
        let resolvedFormat = resolvedFormat(for: snapshot, filename: resolvedFilename)
        let storagePath = SourceVirtualFolderLayout.storagePath(
            for: accountID,
            itemID: snapshot.itemID,
            filename: resolvedFilename
        )
        let resolvedStorageURL = URL(fileURLWithPath: storagePath)
        var track = FullTrack(url: resolvedStorageURL)

        track.trackId = existingTrackID
        track.folderId = folderID
        track.storagePath = storagePath
        track.locatorString = SourceVirtualFolderLayout.locator(for: accountID, itemID: snapshot.itemID)
        track.sourceID = accountID
        track.sourceItemID = snapshot.itemID
        track.localPath = nil
        track.availabilityRawValue = TrackAvailability.online.rawValue
        track.remoteRevision = snapshot.remoteRevision
        track.remoteETag = snapshot.remoteETag
        track.lastSyncedAt = syncedAt
        track.title = snapshot.title
        track.artist = snapshot.artist.isEmpty ? "Unknown Artist" : snapshot.artist
        track.album = snapshot.album.isEmpty ? "Unknown Album" : snapshot.album
        track.composer = snapshot.composer ?? "Unknown Composer"
        track.genre = snapshot.genre ?? "Unknown Genre"
        track.year = snapshot.year.map(String.init) ?? ""
        track.duration = snapshot.duration
        track.trackArtworkData = nil
        track.albumArtworkData = nil
        track.isMetadataLoaded = true
        track.isFavorite = snapshot.isFavorite
        track.playCount = snapshot.playCount
        track.lastPlayedDate = snapshot.lastPlayedDate ?? existingLastPlayedDate
        track.albumArtist = snapshot.albumArtist
        track.trackNumber = snapshot.trackNumber
        track.totalTracks = snapshot.totalTracks
        track.discNumber = snapshot.discNumber
        track.totalDiscs = snapshot.totalDiscs
        track.rating = nil
        track.compilation = false
        track.releaseDate = snapshot.year.map { String($0) }
        track.originalReleaseDate = nil
        track.bpm = nil
        track.mediaType = "Audio"
        track.bitrate = snapshot.bitrate
        track.sampleRate = snapshot.sampleRate
        track.channels = snapshot.channels
        track.codec = snapshot.codec
        track.bitDepth = snapshot.bitDepth
        track.lossless = inferredLosslessFlag(format: resolvedFormat, codec: snapshot.codec)
        track.fileSize = snapshot.fileSize
        track.dateAdded = snapshot.dateAdded ?? syncedAt
        track.dateModified = snapshot.dateModified
        track.isDuplicate = false
        track.primaryTrackId = nil
        track.duplicateGroupId = nil
        track.sortTitle = nil
        track.sortArtist = nil
        track.sortAlbum = nil
        track.sortAlbumArtist = nil
        track.albumId = nil
        track.extendedMetadata = ExtendedMetadata()
        return track
    }

    private func sourceMetadataStub(for snapshot: SourceTrackSnapshot, accountID: String) -> TrackMetadata {
        var metadata = TrackMetadata(
            url: URL(string: SourceVirtualFolderLayout.locator(for: accountID, itemID: snapshot.itemID)) ??
                URL(fileURLWithPath: SourceVirtualFolderLayout.path(for: accountID))
        )
        metadata.title = snapshot.title
        metadata.artist = snapshot.artist
        metadata.album = snapshot.album
        metadata.composer = snapshot.composer
        metadata.genre = snapshot.genre
        metadata.year = snapshot.year.map(String.init)
        metadata.duration = snapshot.duration
        metadata.albumArtist = snapshot.albumArtist
        metadata.trackNumber = snapshot.trackNumber
        metadata.totalTracks = snapshot.totalTracks
        metadata.discNumber = snapshot.discNumber
        metadata.totalDiscs = snapshot.totalDiscs
        metadata.bitrate = snapshot.bitrate
        metadata.sampleRate = snapshot.sampleRate
        metadata.channels = snapshot.channels
        metadata.codec = snapshot.codec
        metadata.bitDepth = snapshot.bitDepth
        metadata.lossless = inferredLosslessFlag(
            format: resolvedFormat(for: snapshot, filename: resolvedFilename(for: snapshot)),
            codec: snapshot.codec
        )
        return metadata
    }

    private func resolvedFilename(for snapshot: SourceTrackSnapshot) -> String {
        if let filename = snapshot.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty {
            return filename
        }

        let baseName = snapshot.title.isEmpty ? snapshot.itemID : snapshot.title
        let format = resolvedFormat(for: snapshot, filename: nil)
        return format.isEmpty ? baseName : "\(baseName).\(format)"
    }

    private func resolvedFormat(for snapshot: SourceTrackSnapshot, filename: String?) -> String {
        if let format = snapshot.format?.trimmingCharacters(in: .whitespacesAndNewlines),
           !format.isEmpty {
            return format.lowercased()
        }

        if let filename, !filename.isEmpty {
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }

        return snapshot.codec?.lowercased() ?? "stream"
    }

    private func inferredLosslessFlag(format: String, codec: String?) -> Bool {
        let candidates = [format.lowercased(), codec?.lowercased() ?? ""]
        return candidates.contains {
            ["flac", "alac", "wav", "aiff", "ape", "wavpack", "tta", "dsf", "dff"].contains($0)
        }
    }
}
