//
// PlaybackManager class
//
// This class handles track playback coordination with PAudioPlayer,
// including database updates, state persistence, and integration with
// PlaylistManager and NowPlayingManager.
//

import AVFoundation
import Foundation

enum RemotePlaybackProgressEvent: String {
    case timeUpdate = "TimeUpdate"
    case pause = "Pause"
    case unpause = "Unpause"
}

enum RemotePlaybackSyncPhase {
    case started
    case progress(RemotePlaybackProgressEvent)
    case stopped(finished: Bool)
}

struct RemotePlaybackSyncState {
    let track: Track
    let position: Double
    let duration: Double
    let isPaused: Bool
    let queueItemIds: [String]
    let currentItemId: String?
    let playSessionId: String
    let startedAt: Date
}

struct RemotePlaybackServerState {
    let currentItemId: String?
    let position: Double
    let lastUpdatedAt: Date?
}

class PlaybackManager: NSObject, ObservableObject {
    private struct PendingStartupSeek {
        let playbackURL: URL
        let trackTitle: String
        let position: Double
    }

    private struct BufferedRemotePlaybackUpdate {
        let state: RemotePlaybackSyncState
        let phase: RemotePlaybackSyncPhase
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
    var bufferedProgress: Double {
        get { playbackProgressState.bufferedProgress }
        set { playbackProgressState.bufferedProgress = newValue }
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
    private var pendingStartupSeek: PendingStartupSeek?
    private var remotePlaybackResolutionTask: Task<Void, Never>?
    private var remotePlaybackRequestID: UUID?
    private var lastNowPlayingInfoUpdateTime: CFAbsoluteTime = 0
    private var scheduledSeekWorkItem: DispatchWorkItem?
    private var scheduledSeekTime: Double?
    private var deferredSeekWorkItem: DispatchWorkItem?
    private var pendingProgressSyncTime: Double?
    private var pendingProgressSyncDeadline: CFAbsoluteTime = 0
    private var cacheProgressObserver: NSObjectProtocol?
    private var remotePlaybackFlushTimer: Timer?
    private var remotePlaybackPollTimer: Timer?
    private var remotePlaybackStartedAt: Date?
    private var remotePlaybackPlaySessionId: String?
    private var bufferedRemotePlaybackUpdate: BufferedRemotePlaybackUpdate?
    private var remotePlaybackSuppressPollingUntil: Date = .distantPast

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
        self.bufferedProgress = 0
        
        observePlaybackCacheProgress()
        startProgressUpdateTimer()
        restoreAudioEffectsSettings()
    }
    
    deinit {
        if let cacheProgressObserver {
            NotificationCenter.default.removeObserver(cacheProgressObserver)
        }
        cancelScheduledSeek()
        cancelDeferredSeek()
        stop()
        stopProgressUpdateTimer()
        stopStateSaveTimer()
        stopRemotePlaybackTimers()
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
        if let previousTrack = currentTrack,
           previousTrack.trackId != track.trackId {
            finalizeRemotePlaybackSync(
                for: previousTrack,
                finished: false,
                position: effectiveCurrentTime
            )
        }

        cancelRemotePlaybackResolution()
        restoredUITrack = nil
        restoredPosition = 0
        
        guard track.isRemote || FileManager.default.fileExists(atPath: track.url.path) else {
            Logger.warning("Track file does not exist: \(track.url.path)")
            NotificationManager.shared.addMessage(.error, "Cannot play '\(track.title)': File not found")
            
            // Auto-skip to next track if in queue
            if playlistManager.currentQueue.count > 1 {
                Logger.info("File not found, skipping to next track in queue")
                playlistManager.playNextTrack()
            }
            return
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
                
                await MainActor.run {
                    self.startPlayback(of: fullTrack, lightweightTrack: track)
                }
            } catch {
                await MainActor.run {
                    Logger.error("Failed to fetch track data: \(error)")
                    NotificationManager.shared.addMessage(.error, "Failed to load track for playback")
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
            if let fullTrack = currentFullTrack, let track = currentTrack, audioPlayer.state != .paused {
                startPlayback(of: fullTrack, lightweightTrack: track)
                isPlaying = true
            } else {
                audioPlayer.resume()
                isPlaying = true
                startStateSaveTimer()
            }
        }
        
        updateNowPlayingInfo()
        let event: RemotePlaybackProgressEvent = isPlaying ? .unpause : .pause
        pushImmediateRemotePlaybackUpdate(event: event)
    }
    
    func stop() {
        if let track = currentTrack {
            finalizeRemotePlaybackSync(for: track, finished: false, position: effectiveCurrentTime)
        }
        cancelScheduledSeek()
        cancelDeferredSeek()
        cancelRemotePlaybackResolution()
        clearPendingProgressSync()
        pendingStartupSeek = nil
        audioPlayer.stop()
        currentTrack = nil
        currentFullTrack = nil
        currentTime = 0
        bufferedProgress = 0
        isPlaying = false
        restoredPosition = 0
        stopStateSaveTimer()
        stopRemotePlaybackTimers()
        Logger.info("Playback stopped")
    }
    
    func stopGracefully() {
        if let track = currentTrack {
            finalizeRemotePlaybackSync(for: track, finished: false, position: effectiveCurrentTime)
        }
        cancelScheduledSeek()
        cancelDeferredSeek()
        cancelRemotePlaybackResolution()
        clearPendingProgressSync()
        pendingStartupSeek = nil
        audioPlayer.stop()
        currentTrack = nil
        currentFullTrack = nil
        currentTime = 0
        bufferedProgress = 0
        isPlaying = false
        stopStateSaveTimer()
        stopRemotePlaybackTimers()
        Logger.info("Playback stopped gracefully")
    }
    
    func seekTo(time: Double) {
        cancelScheduledSeek()
        cancelDeferredSeek()
        let clampedTime = clampedSeekTime(for: time)
        setPendingProgressSync(to: clampedTime)
        currentTime = clampedTime
        restoredPosition = clampedTime

        let didSeek = audioPlayer.seek(to: clampedTime)
        if !didSeek {
            scheduleDeferredSeek(to: clampedTime)
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("PlayerDidSeek"),
            object: nil,
            userInfo: ["time": clampedTime]
        )
        
        if let track = currentTrack {
            nowPlayingManager.updateNowPlayingInfo(
                track: track, currentTime: clampedTime, isPlaying: isPlaying)
            lastNowPlayingInfoUpdateTime = CFAbsoluteTimeGetCurrent()
        }

        pushImmediateRemotePlaybackUpdate(event: .timeUpdate)
    }

    func scheduleSeekTo(time: Double, debounceInterval: TimeInterval = 0.12) {
        let clampedTime = clampedSeekTime(for: time)
        scheduledSeekTime = clampedTime

        scheduledSeekWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let targetTime = self.scheduledSeekTime ?? clampedTime
            self.scheduledSeekWorkItem = nil
            self.scheduledSeekTime = nil
            self.seekTo(time: targetTime)
        }

        scheduledSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    func flushScheduledSeek(time: Double? = nil) {
        let targetTime = time ?? scheduledSeekTime
        cancelScheduledSeek()

        guard let targetTime else { return }
        seekTo(time: targetTime)
    }

    func cancelScheduledSeek() {
        scheduledSeekWorkItem?.cancel()
        scheduledSeekWorkItem = nil
        scheduledSeekTime = nil
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
    
    private func startPlayback(of fullTrack: FullTrack, lightweightTrack: Track) {
        cancelRemotePlaybackResolution()
        pendingStartupSeek = nil
        currentTrack = lightweightTrack
        currentFullTrack = fullTrack
        bufferedProgress = fullTrack.isRemote ? 0 : 1
        
        let seekToPosition = restoredPosition
        restoredPosition = 0

        if fullTrack.isRemote {
            let requestID = UUID()
            remotePlaybackRequestID = requestID
            remotePlaybackResolutionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let playbackURL = try await self.libraryManager.playbackURL(for: lightweightTrack)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.isCurrentRemotePlaybackRequest(lightweightTrack, requestID: requestID) else {
                            Logger.info("Discarded stale remote playback URL for \(lightweightTrack.title)")
                            return
                        }

                        self.startResolvedPlayback(
                            with: playbackURL,
                            lightweightTrack: lightweightTrack,
                            seekToPosition: seekToPosition
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.isCurrentRemotePlaybackRequest(lightweightTrack, requestID: requestID) else {
                            Logger.info("Discarded stale remote playback error for \(lightweightTrack.title)")
                            return
                        }

                        self.remotePlaybackResolutionTask = nil
                        self.remotePlaybackRequestID = nil
                        Logger.error("Failed to prepare remote playback stream: \(error)")
                        NotificationManager.shared.addMessage(.error, "Failed to start remote playback for '\(lightweightTrack.title)'")
                    }
                }
            }
            return
        }

        startResolvedPlayback(
            with: fullTrack.url,
            lightweightTrack: lightweightTrack,
            seekToPosition: seekToPosition
        )
    }

    private func startResolvedPlayback(
        with playbackURL: URL,
        lightweightTrack: Track,
        seekToPosition: Double
    ) {
        remotePlaybackResolutionTask = nil
        remotePlaybackRequestID = nil
        bufferedProgress = playbackURL.isFileURL ? 1 : (lightweightTrack.isRemote ? 0 : 1)

        if seekToPosition > 0 {
            pendingStartupSeek = PendingStartupSeek(
                playbackURL: playbackURL,
                trackTitle: lightweightTrack.title,
                position: seekToPosition
            )
            audioPlayer.play(url: playbackURL, startPaused: true)
            currentTime = seekToPosition
        } else {
            pendingStartupSeek = nil
            currentTime = 0
            audioPlayer.play(url: playbackURL, startPaused: false)
            Logger.info("Started playback: \(lightweightTrack.title)")
        }

        startStateSaveTimer()
        updateNowPlayingInfo()
        scrobbleManager?.trackStarted(lightweightTrack)
        beginRemotePlaybackSync(
            for: lightweightTrack,
            initialPosition: seekToPosition,
            isPaused: seekToPosition > 0
        )

        Task {
            await libraryManager.prefetchRemoteTracks(
                in: playlistManager.currentQueue,
                around: playlistManager.currentQueueIndex
            )
        }
    }

    private func cancelRemotePlaybackResolution() {
        remotePlaybackResolutionTask?.cancel()
        remotePlaybackResolutionTask = nil
        remotePlaybackRequestID = nil
    }

    private func isCurrentRemotePlaybackRequest(_ track: Track, requestID: UUID) -> Bool {
        guard remotePlaybackRequestID == requestID,
              let currentTrack else {
            return false
        }

        return currentTrack.resourceLocator == track.resourceLocator
            && currentTrack.sourceId == track.sourceId
            && currentTrack.remoteItemId == track.remoteItemId
    }

    private func performPendingStartupSeekIfNeeded() {
        guard audioPlayer.state == .paused,
              let pendingStartupSeek else {
            return
        }

        self.pendingStartupSeek = nil

        if audioPlayer.seek(to: pendingStartupSeek.position) {
            currentTime = pendingStartupSeek.position
            audioPlayer.resume()
            Logger.info("Resumed playback: \(pendingStartupSeek.trackTitle) from \(pendingStartupSeek.position)s")
        } else {
            Logger.warning("Seek failed, starting from beginning")
            currentTime = 0
            audioPlayer.play(url: pendingStartupSeek.playbackURL, startPaused: false)
        }
    }

    private func observePlaybackCacheProgress() {
        cacheProgressObserver = NotificationCenter.default.addObserver(
            forName: RemotePlaybackCacheManager.progressDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let key = notification.userInfo?["key"] as? String,
                  let progress = notification.userInfo?["progress"] as? Double,
                  key == self.currentPlaybackCacheProgressKey else {
                return
            }

            self.bufferedProgress = progress
        }
    }

    private var currentPlaybackCacheProgressKey: String? {
        guard let currentTrack, currentTrack.isRemote else { return nil }
        return RemotePlaybackCacheManager.progressKey(for: currentTrack)
    }

    private func clampedSeekTime(for time: Double) -> Double {
        // Clamp seek position to the engine's actual duration to prevent seek
        // errors when the DB-stored duration differs from the actual track
        // duration, this happens in edge-cases for MP3, although it is fixed
        // in MetadataExtractor so hard refresh on library should resolve this.
        let engineDuration = audioPlayer.duration
        let upperBound = engineDuration > 0 ? engineDuration : time
        return max(0, min(time, upperBound))
    }
    
    private func startProgressUpdateTimer() {
        progressUpdateTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(50))
        
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isPlaying else { return }
            let latestProgress = self.audioPlayer.currentPlaybackProgress
            self.currentTime = self.resolvedProgressTime(from: latestProgress)
            self.bufferRemotePlaybackProgressIfNeeded()

            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastNowPlayingInfoUpdateTime >= 1 {
                self.updateNowPlayingInfo()
                self.lastNowPlayingInfoUpdateTime = now
            }
        }
        
        timer.resume()
        progressUpdateTimer = timer
    }
    
    private func stopProgressUpdateTimer() {
        progressUpdateTimer?.cancel()
        progressUpdateTimer = nil
    }

    private func setPendingProgressSync(to time: Double, timeout: CFAbsoluteTime? = nil) {
        let effectiveTimeout = timeout ?? (currentTrack?.isRemote == true ? 2.5 : 1.2)
        pendingProgressSyncTime = time
        pendingProgressSyncDeadline = CFAbsoluteTimeGetCurrent() + effectiveTimeout
    }

    private func clearPendingProgressSync() {
        pendingProgressSyncTime = nil
        pendingProgressSyncDeadline = 0
    }

    private func scheduleDeferredSeek(
        to time: Double,
        retryInterval: TimeInterval = 0.15
    ) {
        guard pendingProgressSyncTime != nil else { return }

        deferredSeekWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performDeferredSeek(to: time, retryInterval: retryInterval)
        }

        deferredSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: workItem)
    }

    private func performDeferredSeek(
        to time: Double,
        retryInterval: TimeInterval
    ) {
        deferredSeekWorkItem = nil

        guard let pendingProgressSyncTime else { return }
        guard abs(pendingProgressSyncTime - time) <= 0.01 else { return }

        if CFAbsoluteTimeGetCurrent() >= pendingProgressSyncDeadline {
            return
        }

        if audioPlayer.seek(to: time) {
            currentTime = time
            restoredPosition = time
            return
        }

        scheduleDeferredSeek(to: time, retryInterval: retryInterval)
    }

    private func cancelDeferredSeek() {
        deferredSeekWorkItem?.cancel()
        deferredSeekWorkItem = nil
    }

    private func resolvedProgressTime(from latestProgress: Double) -> Double {
        guard let pendingProgressSyncTime else {
            return latestProgress
        }

        let now = CFAbsoluteTimeGetCurrent()
        if abs(latestProgress - pendingProgressSyncTime) <= 0.5 || now >= pendingProgressSyncDeadline {
            clearPendingProgressSync()
            return latestProgress
        }

        return pendingProgressSyncTime
    }

    private func beginRemotePlaybackSync(
        for track: Track,
        initialPosition: Double,
        isPaused: Bool
    ) {
        guard track.isRemote else {
            bufferedRemotePlaybackUpdate = nil
            remotePlaybackPlaySessionId = nil
            remotePlaybackStartedAt = nil
            remotePlaybackSuppressPollingUntil = .distantPast
            stopRemotePlaybackTimers()
            return
        }

        remotePlaybackPlaySessionId = UUID().uuidString
        remotePlaybackStartedAt = Date()
        remotePlaybackSuppressPollingUntil = Date().addingTimeInterval(TimeConstants.remotePlaybackInteractionCooldown)
        startRemotePlaybackTimers()

        guard let state = makeRemotePlaybackSyncState(
            for: track,
            position: initialPosition,
            isPaused: isPaused
        ) else {
            return
        }

        enqueueRemotePlaybackUpdate(state: state, phase: .started)
        flushBufferedRemotePlaybackUpdateIfNeeded()
    }

    private func finalizeRemotePlaybackSync(
        for track: Track,
        finished: Bool,
        position: Double
    ) {
        guard track.isRemote else {
            bufferedRemotePlaybackUpdate = nil
            remotePlaybackPlaySessionId = nil
            remotePlaybackStartedAt = nil
            stopRemotePlaybackTimers()
            return
        }

        if let state = makeRemotePlaybackSyncState(
            for: track,
            position: position,
            isPaused: true
        ) {
            enqueueRemotePlaybackUpdate(state: state, phase: .stopped(finished: finished))
            flushBufferedRemotePlaybackUpdateIfNeeded()
        }

        remotePlaybackPlaySessionId = nil
        remotePlaybackStartedAt = nil
        remotePlaybackSuppressPollingUntil = .distantPast
        stopRemotePlaybackTimers()
    }

    private func bufferRemotePlaybackProgressIfNeeded() {
        guard let track = currentTrack,
              let state = makeRemotePlaybackSyncState(for: track) else {
            return
        }

        enqueueRemotePlaybackUpdate(state: state, phase: .progress(.timeUpdate))
    }

    private func pushImmediateRemotePlaybackUpdate(event: RemotePlaybackProgressEvent) {
        guard let track = currentTrack,
              let state = makeRemotePlaybackSyncState(
                for: track,
                isPaused: !isPlaying
              ) else {
            return
        }

        remotePlaybackSuppressPollingUntil = Date().addingTimeInterval(TimeConstants.remotePlaybackInteractionCooldown)
        enqueueRemotePlaybackUpdate(state: state, phase: .progress(event))
        flushBufferedRemotePlaybackUpdateIfNeeded()
    }

    private func makeRemotePlaybackSyncState(
        for track: Track,
        position: Double? = nil,
        isPaused: Bool? = nil
    ) -> RemotePlaybackSyncState? {
        guard track.isRemote,
              let currentItemId = track.remoteItemId,
              let playSessionId = remotePlaybackPlaySessionId,
              let startedAt = remotePlaybackStartedAt else {
            return nil
        }

        return RemotePlaybackSyncState(
            track: track,
            position: max(0, position ?? effectiveCurrentTime),
            duration: track.duration,
            isPaused: isPaused ?? !isPlaying,
            queueItemIds: remoteQueueItemIds(for: track),
            currentItemId: currentItemId,
            playSessionId: playSessionId,
            startedAt: startedAt
        )
    }

    private func remoteQueueItemIds(for track: Track) -> [String] {
        let queueItemIds = playlistManager.currentQueue.compactMap { candidate -> String? in
            guard candidate.sourceKind == track.sourceKind,
                  candidate.sourceId == track.sourceId,
                  let itemId = candidate.remoteItemId else {
                return nil
            }

            return itemId
        }

        if !queueItemIds.isEmpty {
            return queueItemIds
        }

        if let currentItemId = track.remoteItemId {
            return [currentItemId]
        }

        return []
    }

    private func enqueueRemotePlaybackUpdate(
        state: RemotePlaybackSyncState,
        phase: RemotePlaybackSyncPhase
    ) {
        if case .stopped = bufferedRemotePlaybackUpdate?.phase,
           case .progress = phase {
            return
        }

        bufferedRemotePlaybackUpdate = BufferedRemotePlaybackUpdate(state: state, phase: phase)
    }

    private func flushBufferedRemotePlaybackUpdateIfNeeded() {
        guard let update = bufferedRemotePlaybackUpdate else { return }
        bufferedRemotePlaybackUpdate = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                try await self.libraryManager.reportRemotePlayback(update.state, phase: update.phase)
            } catch {
                Logger.warning("Failed to sync remote playback state: \(error)")
                await MainActor.run {
                    if self.bufferedRemotePlaybackUpdate == nil {
                        self.bufferedRemotePlaybackUpdate = update
                    }

                    if self.remotePlaybackFlushTimer == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            self?.flushBufferedRemotePlaybackUpdateIfNeeded()
                        }
                    }
                }
            }
        }
    }

    private func startRemotePlaybackTimers() {
        stopRemotePlaybackTimers()

        remotePlaybackFlushTimer = Timer.scheduledTimer(
            withTimeInterval: TimeConstants.remotePlaybackFlushInterval,
            repeats: true
        ) { [weak self] _ in
            self?.flushBufferedRemotePlaybackUpdateIfNeeded()
        }

        remotePlaybackPollTimer = Timer.scheduledTimer(
            withTimeInterval: TimeConstants.remotePlaybackPollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.pollRemotePlaybackStateIfNeeded()
        }
    }

    private func stopRemotePlaybackTimers() {
        remotePlaybackFlushTimer?.invalidate()
        remotePlaybackFlushTimer = nil
        remotePlaybackPollTimer?.invalidate()
        remotePlaybackPollTimer = nil
    }

    private func pollRemotePlaybackStateIfNeeded() {
        guard Date() >= remotePlaybackSuppressPollingUntil,
              let track = currentTrack,
              let state = makeRemotePlaybackSyncState(for: track) else {
            return
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                guard let serverState = try await self.libraryManager.fetchRemotePlaybackState(for: state) else {
                    return
                }

                await MainActor.run {
                    self.applyRemotePlaybackState(serverState, expectedTrack: state.track)
                }
            } catch {
                Logger.warning("Failed to poll remote playback state: \(error)")
            }
        }
    }

    private func applyRemotePlaybackState(
        _ serverState: RemotePlaybackServerState,
        expectedTrack: Track
    ) {
        guard let currentTrack,
              currentTrack.trackId == expectedTrack.trackId,
              let remoteItemId = currentTrack.remoteItemId else {
            return
        }

        if let currentItemId = serverState.currentItemId,
           currentItemId != remoteItemId {
            return
        }

        let remotePosition = max(0, serverState.position)
        guard remotePosition > 0 else { return }
        guard abs(remotePosition - effectiveCurrentTime) >= TimeConstants.remotePlaybackDriftThreshold else {
            return
        }

        remotePlaybackSuppressPollingUntil = Date().addingTimeInterval(TimeConstants.remotePlaybackInteractionCooldown)
        seekTo(time: remotePosition)
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
}

// MARK: - AudioPlayerDelegate

extension PlaybackManager: AudioPlayerDelegate {
    func audioPlayerDidStartPlaying(player: PAudioPlayer, with entryId: AudioEntryId) {
        DispatchQueue.main.async {
            self.isPlaying = true
            Logger.info("Track started playing: \(entryId.id)")
        }
    }
    
    func audioPlayerStateChanged(player: PAudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        DispatchQueue.main.async {
            let oldIsPlaying = self.isPlaying

            switch newState {
            case .playing:
                self.isPlaying = true
            case .paused:
                self.isPlaying = false
            case .stopped:
                self.isPlaying = false
            case .ready:
                break
            }

            if newState == .paused {
                self.performPendingStartupSeekIfNeeded()
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
            self.pendingStartupSeek = nil
            guard let currentTrack = self.currentTrack else {
                Logger.info("Ignoring finish - no current track")
                return
            }
            
            Logger.info("Track finished (reason: \(stopReason))")

            let finishedNaturally = stopReason == .eof
            let stoppedPosition = finishedNaturally
                ? max(max(progress, duration), self.effectiveCurrentTime)
                : self.effectiveCurrentTime
            self.finalizeRemotePlaybackSync(
                for: currentTrack,
                finished: finishedNaturally,
                position: stoppedPosition
            )
            
            if finishedNaturally {
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
            self.pendingStartupSeek = nil
            if let currentTrack = self.currentTrack {
                self.finalizeRemotePlaybackSync(
                    for: currentTrack,
                    finished: false,
                    position: self.effectiveCurrentTime
                )
            }
            Logger.error("Audio player error: \(error.localizedDescription)")
            NotificationManager.shared.addMessage(.error, "Playback error: \(error.localizedDescription)")
        }
    }
}
