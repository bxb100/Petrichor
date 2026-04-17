//
// PlaybackManager class
//
// This class handles track playback coordination with PAudioPlayer,
// including database updates, state persistence, and integration with
// PlaylistManager and NowPlayingManager.
//

import AVFoundation
import Foundation

private actor RemotePlaybackFileCache {
    private let rootDirectory: URL
    private var inflightDownloads: [String: Task<URL, Error>] = [:]

    init() {
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        rootDirectory = baseDirectory.appendingPathComponent("Petrichor/RemotePlayback", isDirectory: true)
    }

    func materializeFile(
        for track: FullTrack,
        from remoteURL: URL,
        headers: [String: String]
    ) async throws -> URL {
        guard !remoteURL.isFileURL else {
            return remoteURL
        }

        let destinationURL = cachedFileURL(for: track)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let inflightKey = destinationURL.path
        if let inflightTask = inflightDownloads[inflightKey] {
            return try await inflightTask.value
        }

        let task = Task<URL, Error> {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var request = URLRequest(url: remoteURL)
            for (header, value) in headers {
                request.setValue(value, forHTTPHeaderField: header)
            }

            let (temporaryURL, response) = try await URLSession.shared.download(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200 ... 299).contains(httpResponse.statusCode) {
                try? fileManager.removeItem(at: temporaryURL)
                throw URLError(.badServerResponse)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        }

        inflightDownloads[inflightKey] = task

        do {
            let localURL = try await task.value
            inflightDownloads.removeValue(forKey: inflightKey)
            return localURL
        } catch {
            inflightDownloads.removeValue(forKey: inflightKey)
            throw error
        }
    }

    private func cachedFileURL(for track: FullTrack) -> URL {
        let accountComponent = sanitizePathComponent(track.sourceID, maxLength: 64, fallback: "source")
        let itemComponent = sanitizePathComponent(
            track.sourceItemID ?? track.trackId.map(String.init) ?? UUID().uuidString.lowercased(),
            maxLength: 96,
            fallback: "item"
        )
        let revisionComponent = sanitizePathComponent(
            track.remoteRevision ?? track.remoteETag ?? "current",
            maxLength: 48,
            fallback: "current"
        )

        let fileExtension: String
        if track.format.isEmpty {
            fileExtension = "audio"
        } else {
            fileExtension = sanitizePathComponent(track.format.lowercased(), maxLength: 12, fallback: "audio")
        }

        let filename = "\(itemComponent)-\(revisionComponent).\(fileExtension)"
        return rootDirectory
            .appendingPathComponent(accountComponent, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private func sanitizePathComponent(_ rawValue: String, maxLength: Int, fallback: String) -> String {
        let filteredScalars = rawValue.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }

        let sanitized = String(filteredScalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if sanitized.isEmpty {
            return fallback
        }

        return String(sanitized.prefix(maxLength))
    }
}

class PlaybackManager: NSObject, ObservableObject {
    private struct RemotePlaybackSession {
        let entryID: String
        let account: SourceAccountRecord
        let credential: String
        let itemID: String
        let mediaSourceID: String?
        var hasReportedStart = false
        var lastProgressBucket = -1
    }

    private struct PreparedPlayback {
        let fullTrack: FullTrack
        let lightweightTrack: Track
        let playbackURL: URL
        let entryID: String
        let remoteSession: RemotePlaybackSession?
    }

    let playbackProgressState = PlaybackProgressState()
    
    private var scrobbleManager: ScrobbleManager? {
        AppCoordinator.shared?.scrobbleManager
    }

    // MARK: - Published Properties

    @Published var currentTrack: Track?
    @Published var isPlaying: Bool = false {
        didSet {
            NotificationCenter.default.post(
                name: NSNotification.Name("PlaybackStateChanged"), object: nil)
        }
    }
    var currentTime: Double {
        get { playbackProgressState.currentTime }
        set { playbackProgressState.currentTime = newValue }
    }
    @Published var volume: Float = 0.7 {
        didSet {
            audioPlayer.volume = volume
        }
    }
    @Published var restoredUITrack: Track?
    
    // MARK: - Configuration

    var gaplessPlayback: Bool = false
    
    // MARK: - Computed Properties
    
    /// Alias for currentTime for backwards compatibility
    var actualCurrentTime: Double {
        currentTime
    }
    
    var effectiveCurrentTime: Double {
        if currentTime > 0 {
            return currentTime
        }
        return restoredPosition
    }
    
    // MARK: - Private Properties
    
    private let audioPlayer: PAudioPlayer
    private var currentFullTrack: FullTrack?
    private var progressUpdateTimer: DispatchSourceTimer?
    private var stateSaveTimer: Timer?
    private var restoredPosition: Double = 0
    private var activePlaybackEntryID: String?
    private var remotePlaybackSessionsByEntryID: [String: RemotePlaybackSession] = [:]
    private var playbackRequestID = UUID()
    private let remotePlaybackFileCache = RemotePlaybackFileCache()
    
    // MARK: - Dependencies
    
    private let libraryManager: LibraryManager
    private let playlistManager: PlaylistManager
    private let nowPlayingManager: NowPlayingManager
    
    // MARK: - Initialization
    
    init(libraryManager: LibraryManager, playlistManager: PlaylistManager) {
        self.libraryManager = libraryManager
        self.playlistManager = playlistManager
        self.nowPlayingManager = NowPlayingManager()
        self.audioPlayer = PAudioPlayer()
        
        super.init()
        
        self.audioPlayer.delegate = self
        self.audioPlayer.volume = volume
        
        startProgressUpdateTimer()
        restoreAudioEffectsSettings()
    }
    
    deinit {
        stop()
        stopProgressUpdateTimer()
        stopStateSaveTimer()
    }
    
    // MARK: - Player State Management
    
    func restoreUIState(_ uiState: PlaybackUIState) {
        var tempTrack = Track(url: URL(fileURLWithPath: "/restored"))
        tempTrack.title = uiState.trackTitle
        tempTrack.artist = uiState.trackArtist
        tempTrack.album = uiState.trackAlbum
        tempTrack.albumArtworkMedium = uiState.artworkData
        tempTrack.duration = uiState.trackDuration
        tempTrack.isMetadataLoaded = true
        
        restoredUITrack = tempTrack
        currentTrack = tempTrack
        restoredPosition = uiState.playbackPosition
        volume = uiState.volume
        
        nowPlayingManager.updateNowPlayingInfo(
            track: tempTrack,
            currentTime: uiState.playbackPosition,
            isPlaying: false
        )
    }
    
    func prepareTrackForRestoration(_ track: Track, at position: Double) {
        restoredUITrack = nil
        
        Task {
            do {
                guard let fullTrack = try await track.fullTrack(using: libraryManager.databaseManager.dbQueue) else {
                    await MainActor.run {
                        Logger.error("Failed to fetch track data for restoration")
                    }
                    return
                }
                
                await MainActor.run {
                    self.currentTrack = track
                    self.currentFullTrack = fullTrack
                    self.restoredPosition = position
                    self.currentTime = position
                    self.isPlaying = false
                    
                    self.nowPlayingManager.updateNowPlayingInfo(
                        track: track,
                        currentTime: position,
                        isPlaying: false
                    )
                    
                    Logger.info("Prepared track for restoration at position: \(position)")
                }
            } catch {
                await MainActor.run {
                    Logger.error("Failed to prepare track for restoration: \(error)")
                }
            }
        }
    }
    
    // MARK: - Playback Controls
    
    func playTrack(_ track: Track) {
        restoredUITrack = nil
        restoredPosition = 0
        let requestID = UUID()
        playbackRequestID = requestID

        if let localFileURL = track.localFileURL {
            guard FileManager.default.fileExists(atPath: localFileURL.path) else {
                Logger.warning("Track file does not exist: \(localFileURL.path)")
                NotificationManager.shared.addMessage(.error, "Cannot play '\(track.title)': File not found")

                // Auto-skip to next track if in queue
                if playlistManager.currentQueue.count > 1 {
                    Logger.info("File not found, skipping to next track in queue")
                    playlistManager.playNextTrack()
                }
                return
            }
        }
                
        Task {
            do {
                guard let fullTrack = try await track.fullTrack(using: libraryManager.databaseManager.dbQueue) else {
                    await MainActor.run {
                        Logger.error("Failed to fetch full track data for: \(track.title)")
                        NotificationManager.shared.addMessage(.error, "Cannot play track - missing data")
                    }
                    return
                }

                let preparedPlayback = try await preparePlayback(for: track, fullTrack: fullTrack)

                await MainActor.run {
                    guard self.playbackRequestID == requestID else {
                        Logger.info("Discarding stale playback request for \(track.title)")
                        return
                    }

                    self.startPlayback(preparedPlayback)
                }
            } catch {
                await MainActor.run {
                    Logger.error("Failed to prepare track for playback: \(error)")
                    NotificationManager.shared.addMessage(
                        .error,
                        error.localizedDescription.isEmpty ? "Failed to load track for playback" : error.localizedDescription
                    )
                }
            }
        }
    }
    
    func togglePlayPause() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.togglePlayPause()
            }
            return
        }
        
        if isPlaying {
            audioPlayer.pause()
            isPlaying = false
            stopStateSaveTimer()
        } else {
            if currentFullTrack != nil, let track = currentTrack, audioPlayer.state != .paused {
                playTrack(track)
            } else {
                audioPlayer.resume()
                isPlaying = true
                startStateSaveTimer()
            }
        }
        
        updateNowPlayingInfo()
    }
    
    func stop() {
        audioPlayer.stop()
        currentTrack = nil
        currentFullTrack = nil
        currentTime = 0
        isPlaying = false
        restoredPosition = 0
        activePlaybackEntryID = nil
        stopStateSaveTimer()
        Logger.info("Playback stopped")
    }
    
    func stopGracefully() {
        audioPlayer.stop()
        currentTrack = nil
        currentFullTrack = nil
        currentTime = 0
        isPlaying = false
        activePlaybackEntryID = nil
        stopStateSaveTimer()
        Logger.info("Playback stopped gracefully")
    }
    
    func seekTo(time: Double) {
        // Clamp seek position to the engine's actual duration to prevent seek
        // errors when the DB-stored duration differs from the actual track
        // duration, this happens in edge-cases for MP3, although it is fixed
        // in MetadataExtractor so hard refresh on library should resolve this.
        let engineDuration = audioPlayer.duration
        let clampedTime = engineDuration > 0 ? min(time, engineDuration) : time
        audioPlayer.seek(to: clampedTime)
        currentTime = clampedTime
        restoredPosition = clampedTime
        
        NotificationCenter.default.post(
            name: NSNotification.Name("PlayerDidSeek"),
            object: nil,
            userInfo: ["time": time]
        )
        
        if let track = currentTrack {
            nowPlayingManager.updateNowPlayingInfo(
                track: track, currentTime: time, isPlaying: isPlaying)
        }
    }
    
    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
    }
    
    func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        nowPlayingManager.updateNowPlayingInfo(
            track: track,
            currentTime: currentTime,
            isPlaying: isPlaying
        )
    }
    
    // MARK: - Audio Effects

    /// Enable or disable stereo widening effect
    /// - Parameter enabled: true to enable, false to disable
    func setStereoWidening(enabled: Bool) {
        audioPlayer.setStereoWidening(enabled: enabled)
        UserDefaults.standard.set(enabled, forKey: "stereoWideningEnabled")
        Logger.info("Stereo widening \(enabled ? "enabled" : "disabled") via PlaybackManager")
    }

    /// Check if stereo widening is currently enabled
    /// - Returns: true if enabled, false otherwise
    func isStereoWideningEnabled() -> Bool {
        audioPlayer.isStereoWideningEnabled()
    }

    /// Enable or disable the equalizer
    /// - Parameter enabled: true to enable, false to disable
    func setEQEnabled(_ enabled: Bool) {
        audioPlayer.setEQEnabled(enabled)
        UserDefaults.standard.set(enabled, forKey: "eqEnabled")
        Logger.info("EQ \(enabled ? "enabled" : "disabled") via PlaybackManager")
    }

    /// Check if EQ is currently enabled
    /// - Returns: true if enabled, false otherwise
    func isEQEnabled() -> Bool {
        audioPlayer.isEQEnabled()
    }

    /// Apply an EQ preset
    /// - Parameter preset: The EqualizerPreset to apply
    func applyEQPreset(_ preset: EqualizerPreset) {
        audioPlayer.applyEQPreset(preset)
        if preset != .flat && !audioPlayer.isEQEnabled() {
            setEQEnabled(true)
        }
        UserDefaults.standard.set(preset.rawValue, forKey: "eqPreset")
        Logger.info("Applied EQ preset: \(preset.displayName) via PlaybackManager")
    }

    /// Apply custom EQ gains
    /// - Parameter gains: Array of 10 Float values in dB
    func applyEQCustom(gains: [Float]) {
        guard gains.count == 10 else {
            Logger.warning("Invalid EQ gains array size: \(gains.count), expected 10")
            return
        }
        
        audioPlayer.applyEQCustom(gains: gains)
        if !audioPlayer.isEQEnabled() {
            setEQEnabled(true)
        }
        UserDefaults.standard.set(gains, forKey: "customEQGains")
        UserDefaults.standard.set("custom", forKey: "eqPreset")
        Logger.info("Applied custom EQ gains via PlaybackManager")
    }
    
    /// Set the preamp gain
    /// - Parameter gain: Gain value in dB, range -12 to +12
    func setPreamp(_ gain: Float) {
        audioPlayer.setPreamp(gain)
        UserDefaults.standard.set(gain, forKey: "preampGain")
        Logger.info("Preamp set to \(gain) dB via PlaybackManager")
    }

    /// Get the current preamp gain
    /// - Returns: Current preamp gain in dB
    func getPreamp() -> Float {
        audioPlayer.getPreamp()
    }
    
    // MARK: - Private Methods
    
    private func startPlayback(_ preparedPlayback: PreparedPlayback) {
        currentTrack = preparedPlayback.lightweightTrack
        currentFullTrack = preparedPlayback.fullTrack
        activePlaybackEntryID = preparedPlayback.entryID

        if let remoteSession = preparedPlayback.remoteSession {
            remotePlaybackSessionsByEntryID[preparedPlayback.entryID] = remoteSession
        } else {
            remotePlaybackSessionsByEntryID.removeValue(forKey: preparedPlayback.entryID)
        }
        
        let seekToPosition = restoredPosition
        restoredPosition = 0
        
        if seekToPosition > 0 {
            audioPlayer.play(
                url: preparedPlayback.playbackURL,
                startPaused: true,
                entryID: preparedPlayback.entryID
            )
            currentTime = seekToPosition
            
            // Wait for decoder to be ready before resuming playback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self else { return }
                if self.audioPlayer.seek(to: seekToPosition) {
                    self.audioPlayer.resume()
                    Logger.info("Resumed playback: \(preparedPlayback.lightweightTrack.title) from \(seekToPosition)s")
                } else {
                    Logger.warning("Seek failed, starting from beginning")
                    self.currentTime = 0
                    self.audioPlayer.play(
                        url: preparedPlayback.playbackURL,
                        startPaused: false,
                        entryID: preparedPlayback.entryID
                    )
                }
            }
        } else {
            currentTime = 0
            audioPlayer.play(
                url: preparedPlayback.playbackURL,
                startPaused: false,
                entryID: preparedPlayback.entryID
            )
            Logger.info("Started playback: \(preparedPlayback.lightweightTrack.title)")
        }
        
        startStateSaveTimer()
        updateNowPlayingInfo()
        scrobbleManager?.trackStarted(preparedPlayback.lightweightTrack)
    }
    
    private func startProgressUpdateTimer() {
        progressUpdateTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isPlaying else { return }
            self.currentTime = self.audioPlayer.currentPlaybackProgress
            self.updateNowPlayingInfo()
            self.reportRemoteProgressIfNeeded(isPaused: false)
        }
        
        timer.resume()
        progressUpdateTimer = timer
    }
    
    private func stopProgressUpdateTimer() {
        progressUpdateTimer?.cancel()
        progressUpdateTimer = nil
    }
    
    private func startStateSaveTimer() {
        stateSaveTimer?.invalidate()
        stateSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isPlaying {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SavePlaybackState"),
                    object: nil
                )
            }
        }
    }
    
    private func stopStateSaveTimer() {
        stateSaveTimer?.invalidate()
        stateSaveTimer = nil
    }
    
    /// Restore audio effects settings from UserDefaults
    private func restoreAudioEffectsSettings() {
        // Restore stereo widening
        let stereoWideningEnabled = UserDefaults.standard.bool(forKey: "stereoWideningEnabled")
        if stereoWideningEnabled {
            audioPlayer.setStereoWidening(enabled: true)
            Logger.info("Restored stereo widening: enabled")
        }
        
        // Restore EQ enabled state
        let eqEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        if eqEnabled {
            audioPlayer.setEQEnabled(true)
            Logger.info("Restored EQ: enabled")
        }
        
        // Restore EQ preset or custom gains
        if let presetRawValue = UserDefaults.standard.string(forKey: "eqPreset") {
            if presetRawValue == "custom" {
                // Restore custom gains
                if let customGains = UserDefaults.standard.array(forKey: "customEQGains") as? [Float],
                   customGains.count == 10 {
                    audioPlayer.applyEQCustom(gains: customGains)
                    Logger.info("Restored custom EQ gains")
                }
            } else {
                // Restore preset
                if let preset = EqualizerPreset(rawValue: presetRawValue) {
                    audioPlayer.applyEQPreset(preset)
                    Logger.info("Restored EQ preset: \(preset.displayName)")
                }
            }
        }
        
        // Restore preamp gain
        if UserDefaults.standard.object(forKey: "preampGain") != nil {
            let preampGain = UserDefaults.standard.float(forKey: "preampGain")
            audioPlayer.setPreamp(preampGain)
            Logger.info("Restored preamp: \(preampGain) dB")
        }
    }

    private func playbackEntryID(for track: Track, fullTrack: FullTrack) -> String {
        let trackIdentity: String

        if let trackId = track.trackId {
            trackIdentity = "track:\(trackId)"
        } else if let sourceItemID = fullTrack.sourceItemID, !sourceItemID.isEmpty {
            trackIdentity = "source:\(fullTrack.sourceID):\(sourceItemID)"
        } else {
            trackIdentity = "track:\(track.id.uuidString.lowercased())"
        }

        return "\(trackIdentity):\(UUID().uuidString.lowercased())"
    }

    private func preparePlayback(for track: Track, fullTrack: FullTrack) async throws -> PreparedPlayback {
        let entryID = playbackEntryID(for: track, fullTrack: fullTrack)

        guard fullTrack.sourceID != SourceKind.local.rawValue else {
            return PreparedPlayback(
                fullTrack: fullTrack,
                lightweightTrack: track,
                playbackURL: fullTrack.url,
                entryID: entryID,
                remoteSession: nil
            )
        }

        let remotePlayback = try await resolveRemotePlayback(for: fullTrack, entryID: entryID)
        let localPlaybackURL = try await remotePlaybackFileCache.materializeFile(
            for: fullTrack,
            from: remotePlayback.descriptor.streamURL,
            headers: remotePlayback.descriptor.headers
        )
        return PreparedPlayback(
            fullTrack: fullTrack,
            lightweightTrack: track,
            playbackURL: localPlaybackURL,
            entryID: entryID,
            remoteSession: remotePlayback.session
        )
    }

    private func resolveRemotePlayback(
        for fullTrack: FullTrack,
        entryID: String
    ) async throws -> (descriptor: SourcePlaybackDescriptor, session: RemotePlaybackSession) {
        guard let sourceItemID = fullTrack.sourceItemID, !sourceItemID.isEmpty else {
            throw SourceProviderError.unsupportedOperation("Remote track is missing its source item identifier")
        }

        guard let account = libraryManager.databaseManager.getSourceAccount(id: fullTrack.sourceID) else {
            throw SourceProviderError.unsupportedOperation("Remote source account is unavailable")
        }

        let sourceKind = account.kind
        guard sourceKind != .local else {
            throw SourceProviderError.unsupportedOperation("Unknown remote source")
        }

        guard let credential = KeychainManager.retrieve(key: account.tokenRef), !credential.isEmpty else {
            throw SourceProviderError.missingCredential
        }

        guard let provider = await SourceRegistry.shared.provider(for: sourceKind) else {
            throw SourceProviderError.unsupportedOperation("\(sourceKind.displayName) provider is unavailable")
        }

        let preferredContainer = fullTrack.format.isEmpty ? nil : fullTrack.format.lowercased()
        let descriptor = try await provider.resolvePlayback(
            account: account,
            credential: credential,
            itemID: sourceItemID,
            policy: PlaybackPolicy(preferredContainer: preferredContainer, maxBitrateKbps: nil, preferDirectPlay: true)
        )

        return (
            descriptor,
            RemotePlaybackSession(
                entryID: entryID,
                account: account,
                credential: credential,
                itemID: sourceItemID,
                mediaSourceID: descriptor.mediaSourceID
            )
        )
    }

    private func reportRemotePlaybackStarted(for entryID: String) {
        guard var session = remotePlaybackSessionsByEntryID[entryID], !session.hasReportedStart else {
            if remotePlaybackSessionsByEntryID[entryID] != nil {
                reportRemotePlaybackProgress(for: entryID, isPaused: false)
            }
            return
        }

        session.hasReportedStart = true
        remotePlaybackSessionsByEntryID[entryID] = session

        Task {
            guard let provider = await SourceRegistry.shared.provider(for: session.account.kind) else { return }

            await provider.reportPlayback(
                account: session.account,
                credential: session.credential,
                event: .started(
                    itemID: session.itemID,
                    mediaSourceID: session.mediaSourceID,
                    positionSeconds: currentTime,
                    queueIndex: playlistManager.currentQueueIndex,
                    queueLength: playlistManager.currentQueue.count
                )
            )
        }
    }

    private func reportRemoteProgressIfNeeded(isPaused: Bool) {
        guard let entryID = activePlaybackEntryID else { return }
        guard var session = remotePlaybackSessionsByEntryID[entryID], session.hasReportedStart else { return }

        let bucket = Int(currentTime) / 10
        guard isPaused || bucket > session.lastProgressBucket else { return }

        session.lastProgressBucket = bucket
        remotePlaybackSessionsByEntryID[entryID] = session
        reportRemotePlaybackProgress(for: entryID, isPaused: isPaused)
    }

    private func reportRemotePlaybackProgress(for entryID: String, isPaused: Bool) {
        guard let session = remotePlaybackSessionsByEntryID[entryID] else { return }

        Task {
            guard let provider = await SourceRegistry.shared.provider(for: session.account.kind) else { return }

            await provider.reportPlayback(
                account: session.account,
                credential: session.credential,
                event: .progress(
                    itemID: session.itemID,
                    mediaSourceID: session.mediaSourceID,
                    positionSeconds: currentTime,
                    isPaused: isPaused
                )
            )
        }
    }

    private func reportRemotePlaybackStopped(for entryID: String, position: Double) {
        guard let session = remotePlaybackSessionsByEntryID.removeValue(forKey: entryID) else { return }

        if activePlaybackEntryID == entryID {
            activePlaybackEntryID = nil
        }

        Task {
            guard let provider = await SourceRegistry.shared.provider(for: session.account.kind) else { return }

            await provider.reportPlayback(
                account: session.account,
                credential: session.credential,
                event: .stopped(
                    itemID: session.itemID,
                    mediaSourceID: session.mediaSourceID,
                    positionSeconds: position
                )
            )
        }
    }
}

// MARK: - AudioPlayerDelegate

extension PlaybackManager: AudioPlayerDelegate {
    func audioPlayerDidStartPlaying(player: PAudioPlayer, with entryId: AudioEntryId) {
        DispatchQueue.main.async {
            self.isPlaying = true
            self.reportRemotePlaybackStarted(for: entryId.id)
            Logger.info("Track started playing: \(entryId.id)")
        }
    }
    
    func audioPlayerStateChanged(player: PAudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        DispatchQueue.main.async {
            let oldIsPlaying = self.isPlaying

            switch newState {
            case .playing:
                self.isPlaying = true
                self.reportRemoteProgressIfNeeded(isPaused: false)
            case .paused:
                self.isPlaying = false
                self.reportRemoteProgressIfNeeded(isPaused: true)
            case .stopped:
                self.isPlaying = false
            case .ready:
                break
            }
            
            if oldIsPlaying != self.isPlaying {
                self.updateNowPlayingInfo()
            }
            Logger.info("Player state changed: \(previous) → \(newState)")
        }
    }
    
    func audioPlayerDidFinishPlaying(
        player: PAudioPlayer,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress: Double,
        duration: Double
    ) {
        DispatchQueue.main.async {
            let isActiveFinish = self.activePlaybackEntryID == nil || entryId.id == self.activePlaybackEntryID
            self.reportRemotePlaybackStopped(for: entryId.id, position: progress)

            guard isActiveFinish else {
                Logger.info("Ignoring finish for stale playback entry: \(entryId.id)")
                return
            }

            self.activePlaybackEntryID = nil

            guard let currentTrack = self.currentTrack else {
                Logger.info("Ignoring finish - no current track")
                return
            }
            
            Logger.info("Track finished (reason: \(stopReason))")
            
            if stopReason == .eof {
                self.playlistManager.incrementPlayCount(for: currentTrack)
                self.scrobbleManager?.trackFinished(currentTrack)
                
                Logger.info("Track completed naturally, updating play count, last played date, and scrobbling it if configured")
            }
            
            self.currentTime = 0
            
            switch stopReason {
            case .eof:
                self.restoredPosition = 0
                if self.gaplessPlayback {
                    self.playlistManager.playNextTrack()
                } else {
                    self.playlistManager.handleTrackCompletion()
                    if !self.isPlaying {
                        self.stopStateSaveTimer()
                        
                        NotificationCenter.default.post(
                            name: NSNotification.Name("SavePlaybackState"),
                            object: nil
                        )
                    }
                }
                
            case .userAction:
                self.stopStateSaveTimer()
                
            case .error:
                self.isPlaying = false
                Logger.error("Playback finished with error")
                NotificationManager.shared.addMessage(.error, "Playback error occurred")
            }
        }
    }
    
    func audioPlayerUnexpectedError(player: PAudioPlayer, error: AudioPlayerError) {
        DispatchQueue.main.async {
            Logger.error("Audio player error: \(error.localizedDescription)")
            NotificationManager.shared.addMessage(.error, "Playback error: \(error.localizedDescription)")
        }
    }
}
