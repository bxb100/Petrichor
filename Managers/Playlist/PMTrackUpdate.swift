//
// PlaylistManager class extension
//
// This extension contains methods for updating individual tracks based on user
// interaction events like marking as favorite, play count, last played, etc.
// The methods internally also use DatabaseManager methods to work with database.
//

import Foundation
import GRDB

extension PlaylistManager {
    func updateTrackFavoriteStatus(track: Track, isFavorite: Bool) async {
        guard let trackId = track.trackId else {
            Logger.error("Cannot update favorite - track has no database ID")
            return
        }

        let updatedTrack = track.withFavoriteStatus(isFavorite)

        do {
            if let dbManager = libraryManager?.databaseManager {
                try await dbManager.updateTrackFavoriteStatus(trackId: trackId, isFavorite: isFavorite)
                await syncFavoriteStatusToRemoteSource(for: track, isFavorite: isFavorite)

                Logger.info("Updated favorite status for track: \(track.title) to \(isFavorite)")
                
                await handleTrackPropertyUpdate(updatedTrack)
                
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .trackFavoriteStatusChanged,
                        object: nil,
                        userInfo: ["track": updatedTrack]
                    )
                }
                
                if let favoritesIndex = playlists.firstIndex(where: {
                    $0.name == DefaultPlaylists.favorites && $0.type == .smart
                }) {
                    Task.detached(priority: .background) { [weak self] in
                        guard let self = self else { return }
                        await self.loadSmartPlaylistTracks(self.playlists[favoritesIndex])
                    }
                }
            }
        } catch {
            Logger.error("Failed to update favorite status: \(error)")
        }
    }

    private func syncFavoriteStatusToRemoteSource(for track: Track, isFavorite: Bool) async {
        guard !track.isLocalSource else {
            return
        }

        guard let sourceItemID = track.sourceItemID, !sourceItemID.isEmpty else {
            Logger.warning("Skipping remote favorite sync for \(track.title): missing source item ID")
            return
        }

        guard let dbManager = libraryManager?.databaseManager,
              let account = dbManager.getSourceAccount(id: track.sourceID) else {
            Logger.warning("Skipping remote favorite sync for \(track.title): missing source account")
            return
        }

        let sourceKind = account.kind
        guard sourceKind != .local else {
            Logger.warning("Skipping remote favorite sync for \(track.title): unknown remote source")
            return
        }

        guard let credential = KeychainManager.retrieve(key: account.tokenRef), !credential.isEmpty else {
            Logger.warning("Skipping remote favorite sync for \(track.title): missing source credential")
            return
        }

        do {
            guard let provider = await SourceRegistry.shared.provider(for: sourceKind) else {
                Logger.warning("Skipping remote favorite sync for \(track.title): provider unavailable")
                return
            }

            try await provider.setFavorite(
                account: account,
                credential: credential,
                itemID: sourceItemID,
                isFavorite: isFavorite
            )

            Logger.info("Synced favorite status to \(sourceKind.displayName) for track: \(track.title)")
        } catch {
            Logger.warning("Failed to sync favorite status to \(sourceKind.displayName): \(error.localizedDescription)")
            NotificationManager.shared.addMessage(
                .warning,
                "Updated favorite locally, but failed to sync \(track.title) to \(sourceKind.displayName)"
            )
        }
    }

    /// Add or remove a track from any playlist (handles both regular and smart playlists)
    func updateTrackInPlaylist(track: Track, playlist: Playlist, add: Bool) {
        Task {
            do {
                guard libraryManager?.databaseManager != nil else { return }

                // Handle smart playlists differently
                if playlist.type == .smart {
                    // For smart playlists, we update the track property that controls membership
                    if playlist.name == DefaultPlaylists.favorites && !playlist.isUserEditable {
                        // Update favorite status
                        await updateTrackFavoriteStatus(track: track, isFavorite: add)
                    }
                    // Other smart playlists are read-only
                    return
                }

                // For regular playlists, add/remove from playlist
                if add {
                    await addTrackToRegularPlaylist(track: track, playlistID: playlist.id)
                } else {
                    await removeTrackFromRegularPlaylist(track: track, playlistID: playlist.id)
                }
            }
        }
    }

    /// Update play count for a track
    func incrementPlayCount(for track: Track) {
        Task {
            guard let trackId = track.trackId else {
                Logger.error("Cannot update play count - track has no database ID")
                return
            }
            
            guard let dbManager = libraryManager?.databaseManager else {
                Logger.error("Cannot update play count - no database manager")
                return
            }

            do {
                let currentPlayCount = try await dbManager.getTrackPlayCount(trackId: trackId) ?? track.playCount
                let newPlayCount = currentPlayCount + 1
                let lastPlayedDate = Date()

                try await dbManager.updatePlayingTrackMetadata(
                    trackId: trackId,
                    playCount: newPlayCount,
                    lastPlayedDate: lastPlayedDate
                )

                _ = track.withPlayStats(playCount: newPlayCount, lastPlayedDate: lastPlayedDate)

                Logger.info("Incremented play count for track: \(track.title) (now: \(newPlayCount))")
                
                updateSmartPlaylistCounts()
                
                // Refresh smart playlists affected by play count/last played changes
                Task.detached(priority: .background) { [weak self] in
                    guard let self = self else { return }
                    
                    for playlist in self.playlists where playlist.type == .smart && !playlist.isUserEditable {
                        if playlist.name == DefaultPlaylists.mostPlayed ||
                           playlist.name == DefaultPlaylists.recentlyPlayed {
                            await self.loadSmartPlaylistTracks(playlist)
                        }
                    }
                }
            } catch {
                Logger.error("Failed to update play count: \(error)")
            }
        }
    }

    /// Handle track property updates to refresh smart playlists and other dependent data
    internal func handleTrackPropertyUpdate(_ track: Track) async {
        // Update current queue if the track is in it
        await MainActor.run {
            if let queueIndex = self.currentQueue.firstIndex(where: { $0.trackId == track.trackId }) {
                self.currentQueue[queueIndex] = track
            }
        }

        // Update current track if it's the one being updated
        if let currentTrack = audioPlayer?.currentTrack, currentTrack.trackId == track.trackId {
            await MainActor.run {
                self.audioPlayer?.currentTrack = track
            }
        }
    }

    /// Handle the start of track playback
    func handleTrackPlaybackStarted(_ track: Track) {
        Task {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TrackPlaybackStarted"),
                    object: nil,
                    userInfo: ["track": track]
                )
            }
        }
    }

    /// Handle track playback completion
    func handleTrackPlaybackCompleted(_ track: Track) {
        // Increment play count when track completes
        incrementPlayCount(for: track)
    }
}
