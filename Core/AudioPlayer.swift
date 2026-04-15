import AVFoundation
import Foundation
import SFBAudioEngine

typealias SFBPlayer = SFBAudioEngine.AudioPlayer
typealias SFBPlayerPlaybackState = SFBAudioEngine.AudioPlayer.PlaybackState
typealias SFBDecoding = SFBAudioEngine.PCMDecoding

// MARK: - Audio Player State

public enum AudioPlayerState {
    case ready
    case playing
    case paused
    case stopped
}

// MARK: - Audio Player Stop Reason

public enum AudioPlayerStopReason {
    case eof
    case userAction
    case error
}

// MARK: - Audio Player Error

public enum AudioPlayerError: Error {
    case fileNotFound
    case invalidFormat
    case engineError(Error)
    case seekError
    case invalidState

    var localizedDescription: String {
        switch self {
        case .fileNotFound:
            return "Audio file not found"
        case .invalidFormat:
            return "Unsupported audio format"
        case .engineError(let error):
            return "Audio engine error: \(error.localizedDescription)"
        case .seekError:
            return "Failed to seek to position"
        case .invalidState:
            return "Invalid player state for this operation"
        }
    }
}

// MARK: - Audio Entry ID

public struct AudioEntryId: Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for receiving playback events
public protocol AudioPlayerDelegate: AnyObject {
    func audioPlayerDidStartPlaying(player: PAudioPlayer, with entryId: AudioEntryId)
    func audioPlayerStateChanged(player: PAudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState)
    func audioPlayerDidFinishPlaying(
        player: PAudioPlayer,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress: Double,
        duration: Double
    )
    func audioPlayerUnexpectedError(player: PAudioPlayer, error: AudioPlayerError)

    // Optional methods with default implementations
    func audioPlayerDidFinishBuffering(player: PAudioPlayer, with entryId: AudioEntryId)
    func audioPlayerDidReadMetadata(player: PAudioPlayer, metadata: [String: String])
    func audioPlayerDidCancel(player: PAudioPlayer, queuedItems: [AudioEntryId])
}

// MARK: - Default Implementations

public extension AudioPlayerDelegate {
    func audioPlayerDidFinishBuffering(player: PAudioPlayer, with entryId: AudioEntryId) {}
    func audioPlayerDidReadMetadata(player: PAudioPlayer, metadata: [String: String]) {}
    func audioPlayerDidCancel(player: PAudioPlayer, queuedItems: [AudioEntryId]) {}
}

// MARK: - PAudioPlayer

public class PAudioPlayer: NSObject {
    private enum PlaybackBackend {
        case local
        case remote
    }

    // MARK: - Public Properties

    public weak var delegate: AudioPlayerDelegate?

    public var volume: Float {
        get {
            currentVolume
        }
        set {
            currentVolume = newValue

            do {
                try sfbPlayer.setVolume(newValue)
            } catch {
                Logger.error("Failed to set volume: \(error)")
            }

            applyRemoteVolume()
        }
    }

    public private(set) var state: AudioPlayerState = .ready {
        didSet {
            guard oldValue != state else { return }
            let newState = state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioPlayerStateChanged(player: self, with: newState, previous: oldValue)
            }
        }
    }

    /// Current playback progress in seconds
    public var currentPlaybackProgress: Double {
        switch activeBackend {
        case .local:
            return sfbPlayer.currentTime ?? 0
        case .remote:
            guard let player = avPlayer else { return 0 }
            let seconds = CMTimeGetSeconds(player.currentTime())
            return seconds.isFinite && !seconds.isNaN && seconds >= 0 ? seconds : 0
        }
    }

    /// Total duration of current file in seconds
    public var duration: Double {
        switch activeBackend {
        case .local:
            return sfbPlayer.totalTime ?? 0
        case .remote:
            guard let item = avPlayer?.currentItem else { return 0 }
            let seconds = CMTimeGetSeconds(item.duration)
            return seconds.isFinite && !seconds.isNaN && seconds > 0 ? seconds : 0
        }
    }

    /// Legacy property name for backwards compatibility
    public var progress: Double {
        return currentPlaybackProgress
    }

    // MARK: - Private Properties

    private let sfbPlayer: SFBPlayer
    private var activeBackend: PlaybackBackend = .local
    private var currentEntryId: AudioEntryId?
    private var currentURL: URL?
    private var delegateBridge: SFBAudioPlayerDelegateBridge?
    private var pauseWhenPlaybackStarts = false
    private var currentVolume: Float = 1.0
    private static let maxPreBufferSize: UInt64 = 100 * 1024 * 1024
    private var avPlayer: AVPlayer?
    private var avPlayerStatusObserver: NSKeyValueObservation?
    private var avPlayerTimeControlObserver: NSKeyValueObservation?
    private var avPlayerItemEndObserver: NSObjectProtocol?
    private var avPlayerItemFailedObserver: NSObjectProtocol?
    private var remoteDidStartPlaying = false
    private var remoteStopInProgress = false

    // MARK: - Audio Effects Nodes

    private var effectsAttached = false

    /// Stereo Widening
    private var stereoWideningEnabled: Bool = false
    private var stereoWideningNode: AVAudioUnit?

    /// Equalizer
    private var eqEnabled: Bool = false
    private var eqNode: AVAudioUnitEQ?
    private var preampGain: Float = 0.0
    private var userPreampGain: Float = 0.0
    private var currentEQGains: [Float] = Array(repeating: 0.0, count: 10)
    private let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private var lastRouteRecoveryAttemptTime: CFAbsoluteTime = 0

    // MARK: - Initialization

    public override init() {
        self.sfbPlayer = SFBPlayer()
        super.init()

        // Create and set up the delegate bridge for playback event monitoring
        self.delegateBridge = SFBAudioPlayerDelegateBridge(owner: self)
        self.sfbPlayer.delegate = self.delegateBridge
    }

    deinit {
        teardownRemotePlayback()
        sfbPlayer.stop()
    }

    // MARK: - Playback Control

    /// Play an audio file from URL
    /// - Parameters:
    ///   - url: The URL of the audio file
    ///   - startPaused: If true, loads the file but doesn't start playback
    public func play(url: URL, startPaused: Bool = false) {
        currentURL = url
        let entryId = AudioEntryId(id: url.isFileURL ? url.lastPathComponent : url.path)
        currentEntryId = entryId
        pauseWhenPlaybackStarts = startPaused

        if url.isFileURL {
            activeBackend = .local
            teardownRemotePlayback()
            playLocal(url: url, startPaused: startPaused, entryId: entryId)
        } else {
            activeBackend = .remote
            sfbPlayer.stop()
            playRemote(url: url, startPaused: startPaused, entryId: entryId)
        }
    }

    /// Pause playback
    public func pause() {
        guard state == .playing else { return }
        pauseWhenPlaybackStarts = false

        switch activeBackend {
        case .local:
            sfbPlayer.pause()
            state = .paused
        case .remote:
            avPlayer?.pause()
            state = .paused
        }

        Logger.info("Playback paused")
    }

    /// Resume playback
    public func resume() {
        guard state == .paused else { return }
        pauseWhenPlaybackStarts = false

        switch activeBackend {
        case .local:
            do {
                try sfbPlayer.play()
                state = .playing
                Logger.info("Playback resumed")
            } catch {
                Logger.error("Failed to resume playback: \(error)")
                delegate?.audioPlayerUnexpectedError(player: self, error: .engineError(error))
            }
        case .remote:
            avPlayer?.play()
            if state != .playing {
                state = .playing
            }
            Logger.info("Remote playback resumed")
        }
    }

    /// Stop playback
    public func stop() {
        guard state != .stopped else { return }
        switch activeBackend {
        case .local:
            stopLocalPlayback(notifyFinish: true)
        case .remote:
            stopRemotePlayback(notifyFinish: true)
        }
    }

    /// Toggle between play and pause
    public func togglePlayPause() {
        switch activeBackend {
        case .local:
            do {
                try sfbPlayer.togglePlayPause()

                switch sfbPlayer.playbackState {
                case .playing:
                    state = .playing
                case .paused:
                    state = .paused
                case .stopped:
                    state = .stopped
                @unknown default:
                    break
                }
            } catch {
                Logger.error("Failed to toggle play/pause: \(error)")
                delegate?.audioPlayerUnexpectedError(player: self, error: .engineError(error))
            }
        case .remote:
            if state == .playing {
                pause()
            } else if state == .paused || state == .ready {
                resume()
            }
        }
    }

    /// Seek to a specific time in seconds
    /// - Parameter time: The target time in seconds
    /// - Returns: true if seek was successful
    @discardableResult
    public func seek(to time: Double) -> Bool {
        guard time >= 0 else { return false }

        switch activeBackend {
        case .local:
            let success = sfbPlayer.seek(time: time)

            if !success {
                Logger.error("Failed to seek to time: \(time)")
                delegate?.audioPlayerUnexpectedError(player: self, error: .seekError)
            }

            return success
        case .remote:
            guard let player = avPlayer, player.currentItem != nil else { return false }
            let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            return true
        }
    }

    /// Seek forward by a number of seconds
    /// - Parameter seconds: Number of seconds to skip forward
    /// - Returns: true if seek was successful
    @discardableResult
    public func seekForward(_ seconds: Double) -> Bool {
        switch activeBackend {
        case .local:
            return sfbPlayer.seek(forward: seconds)
        case .remote:
            return seek(to: currentPlaybackProgress + seconds)
        }
    }

    /// Seek backward by a number of seconds
    /// - Parameter seconds: Number of seconds to skip backward
    /// - Returns: true if seek was successful
    @discardableResult
    public func seekBackward(_ seconds: Double) -> Bool {
        switch activeBackend {
        case .local:
            return sfbPlayer.seek(backward: seconds)
        case .remote:
            return seek(to: max(0, currentPlaybackProgress - seconds))
        }
    }

    // MARK: - Audio Equalizer

    /// Enable or disable stereo widening effect
    /// - Parameter enabled: boolean for the current state of stereo widening
    public func setStereoWidening(enabled: Bool) {
        stereoWideningEnabled = enabled

        if !effectsAttached {
            setupAudioEffects()
        }

        if let effectNode = stereoWideningNode as? AVAudioUnitEffect {
            effectNode.bypass = !enabled
        }

        Logger.info("Stereo Widening \(enabled ? "enabled" : "disabled")")
    }

    /// Check if stereo widening is currently enabled
    /// - Returns: true if Stereo Widening is enabled, false otherwise
    public func isStereoWideningEnabled() -> Bool {
        return stereoWideningEnabled
    }

    /// Enable or disable the equalizer
    /// - Parameter enabled: boolean for the current state Equalizer
    public func setEQEnabled(_ enabled: Bool) {
        eqEnabled = enabled

        if !effectsAttached {
            setupAudioEffects()
        }

        eqNode?.bypass = !enabled

        applyEffectivePreamp()

        Logger.info("Audio Equalizer \(enabled ? "enabled" : "disabled")")
    }

    /// Check if EQ is currently enabled
    /// - Returns: true if Equalizer is enabled, false otherwise
    public func isEQEnabled() -> Bool {
        return eqEnabled
    }

    /// Apply an EQ preset
    /// - Parameter preset: The EqualizerPreset to apply
    public func applyEQPreset(_ preset: EqualizerPreset) {
        currentEQGains = preset.gains

        if !effectsAttached {
            setupAudioEffects()
        }

        if let eq = eqNode {
            for (index, gain) in currentEQGains.enumerated() {
                eq.bands[index].gain = gain
            }
        }

        applyEffectivePreamp()

        Logger.info("Applied Equalizer preset: \(preset.displayName)")
    }

    /// Apply custom EQ gains
    /// - Parameter gains: Array of 10 gain values in dB (one for each frequency band)
    public func applyEQCustom(gains: [Float]) {
        guard gains.count == 10 else {
            Logger.warning("Equalizer gains array must contain exactly 10 values, got \(gains.count)")
            return
        }

        currentEQGains = gains

        if !effectsAttached {
            setupAudioEffects()
        }

        if let eq = eqNode {
            for (index, gain) in gains.enumerated() {
                eq.bands[index].gain = gain
            }
        }

        applyEffectivePreamp()

        Logger.info("Applied custom Equalizer gains")
    }

    /// Set the preamp gain (affects overall volume before EQ)
    /// - Parameter gain: Gain value in dB, typically -12 to +12
    /// - Note: Preamp adjusts the signal level before EQ processing
    public func setPreamp(_ gain: Float) {
        userPreampGain = max(-12.0, min(12.0, gain))
        applyEffectivePreamp()
        Logger.info("Preamp set to \(userPreampGain) dB (effective: \(preampGain) dB)")
    }

    /// Get the current preamp gain value
    /// - Returns: Current preamp gain in dB
    public func getPreamp() -> Float {
        return userPreampGain
    }

    // MARK: - Internal Methods (called by delegate bridge)

    internal func handlePlaybackStateChanged(_ newState: SFBPlayerPlaybackState) {
        guard activeBackend == .local else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch newState {
            case .playing:
                if self.pauseWhenPlaybackStarts {
                    self.pauseWhenPlaybackStarts = false
                    self.sfbPlayer.pause()
                    self.state = .paused
                    Logger.info("Playback primed in paused state")
                    return
                }

                if self.state != .playing {
                    self.state = .playing
                    if let entryId = self.currentEntryId {
                        self.delegate?.audioPlayerDidStartPlaying(player: self, with: entryId)
                    }
                }
            case .paused:
                if self.state != .paused {
                    self.state = .paused
                }
            case .stopped:
                if self.state != .stopped {
                    self.state = .stopped
                }
            @unknown default:
                break
            }
        }
    }

    internal func handleEndOfAudio() {
        guard activeBackend == .local else { return }

        let finalProgress = currentPlaybackProgress
        let finalDuration = duration

        if let entryId = currentEntryId {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.state = .stopped
                self.delegate?.audioPlayerDidFinishPlaying(
                    player: self,
                    entryId: entryId,
                    stopReason: .eof,
                    progress: finalProgress,
                    duration: finalDuration
                )

                self.currentURL = nil
                self.currentEntryId = nil
            }
        }
    }

    /// Reconfigures the audio processing graph when the format changes
    /// This is called by SFBAudioEngine when switching between different sample rates
    internal func reconfigureAudioGraph(engine: AVAudioEngine, format: AVAudioFormat) -> AVAudioNode {
        Logger.info("Reconfiguring audio graph for format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        guard effectsAttached else {
            Logger.info("No effects attached, connecting directly to mixer")
            return engine.mainMixerNode
        }

        // Detach and recreate effect nodes with the new format
        if let oldStereoNode = stereoWideningNode {
            engine.detach(oldStereoNode)
            stereoWideningNode = nil
        }

        if let oldEQNode = eqNode {
            engine.detach(oldEQNode)
            eqNode = nil
        }

        // Recreate the effects chain
        setupStereoWidening(engine: engine)
        setupEqualizer(engine: engine)

        let mainMixer = engine.mainMixerNode

        if let stereoNode = stereoWideningNode, let equalizer = eqNode {
            engine.connect(stereoNode, to: equalizer, format: format)
            engine.connect(equalizer, to: mainMixer, format: format)
            Logger.info("Reconfigured audio graph: playerNode -> stereoWidening -> EQ -> mainMixer")

            return stereoNode
        }

        Logger.warning("Failed to reconfigure effects chain, falling back to mixer")
        return mainMixer
    }

    internal func handleError(_ error: Error) {
        guard activeBackend == .local else { return }

        if attemptLocalPlaybackRecovery(from: error) {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioPlayerUnexpectedError(player: self, error: .engineError(error))
        }
    }

    private func handleAVPlayerTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        guard activeBackend == .remote else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.remoteStopInProgress else { return }

            switch status {
            case .waitingToPlayAtSpecifiedRate:
                guard self.state != .paused, self.state != .stopped else { return }
                if self.state != .ready {
                    self.state = .ready
                }
            case .playing:
                if self.pauseWhenPlaybackStarts {
                    self.pauseWhenPlaybackStarts = false
                    self.avPlayer?.pause()
                    self.state = .paused
                    Logger.info("Remote playback primed in paused state")
                    return
                }

                if self.state != .playing {
                    self.state = .playing
                }

                if !self.remoteDidStartPlaying, let entryId = self.currentEntryId {
                    self.remoteDidStartPlaying = true
                    self.delegate?.audioPlayerDidStartPlaying(player: self, with: entryId)
                }
            case .paused:
                guard self.state != .stopped else { return }
                if self.state != .paused {
                    self.state = .paused
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Private Methods

    private static func shouldPreBuffer(url: URL) -> Bool {
        // Only consider pre-buffering for files under the size threshold
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(fileSize) <= maxPreBufferSize else {
            return false
        }

        // Check if the file is on a network volume
        if let resourceValues = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = resourceValues.volumeIsLocal,
           !isLocal {
            return true
        }

        // Check filesystem type for FUSE-based mounts
        if FilesystemUtils.isSlowFilesystem(url: url) {
            return true
        }

        return false
    }

    private func playLocal(url: URL, startPaused: Bool, entryId: AudioEntryId) {
        let shouldPreBuffer = Self.shouldPreBuffer(url: url)

        if shouldPreBuffer {
            state = .ready

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                do {
                    let inputSource = try InputSource(for: url, flags: .loadFilesInMemory)
                    let decoder = try AudioDecoder(inputSource: inputSource)

                    try self.sfbPlayer.play(decoder)

                    DispatchQueue.main.async {
                        if !startPaused {
                            self.state = .playing
                        }
                        Logger.info(
                            startPaused
                                ? "Prepared playback (pre-buffered): \(url.lastPathComponent)"
                                : "Started playing (pre-buffered): \(url.lastPathComponent)"
                        )
                    }
                } catch {
                    Logger.warning("Pre-buffering failed, falling back to direct playback: \(error.localizedDescription)")

                    do {
                        try self.sfbPlayer.play(url)

                        DispatchQueue.main.async {
                            if !startPaused {
                                self.state = .playing
                            }
                            Logger.info(
                                startPaused
                                    ? "Prepared playback (direct fallback): \(url.lastPathComponent)"
                                    : "Started playing (direct fallback): \(url.lastPathComponent)"
                            )
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.handlePlaybackError(error, entryId: entryId)
                        }
                    }
                }
            }
        } else {
            do {
                try sfbPlayer.play(url)

                if startPaused {
                    state = .ready
                } else {
                    state = .playing
                }

                Logger.info(
                    startPaused
                        ? "Prepared playback: \(url.lastPathComponent)"
                        : "Started playing: \(url.lastPathComponent)"
                )
            } catch {
                handlePlaybackError(error, entryId: entryId)
            }
        }
    }

    private func playRemote(url: URL, startPaused: Bool, entryId: AudioEntryId) {
        teardownRemotePlayback()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = currentVolume
        player.automaticallyWaitsToMinimizeStalling = true

        avPlayer = player
        remoteDidStartPlaying = false
        remoteStopInProgress = false

        // Observe AVPlayerItem status for load failures
        avPlayerStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, !self.remoteStopInProgress else { return }
            if item.status == .failed {
                Logger.error("AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
                self.handleRemotePlaybackFailure(item.error ?? AudioPlayerError.invalidFormat)
            }
        }

        // Observe time control status (playing / paused / buffering)
        avPlayerTimeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            self?.handleAVPlayerTimeControlStatus(player.timeControlStatus)
        }

        // Observe natural playback end
        avPlayerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard self?.remoteStopInProgress == false else { return }
            self?.handleRemotePlaybackEnded()
        }

        // Observe playback failure mid-stream
        avPlayerItemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard self?.remoteStopInProgress == false else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Logger.error("Remote stream failed to play to end: \(error?.localizedDescription ?? "unknown")")
            self?.handleRemotePlaybackFailure(error ?? AudioPlayerError.invalidFormat)
        }

        state = startPaused ? .ready : .playing
        if !startPaused {
            player.play()
        }

        Logger.info(
            startPaused
                ? "Preparing remote stream: \(redactedURLString(url))"
                : "Started remote stream: \(redactedURLString(url))"
        )
    }

    private func handleRemotePlaybackEnded() {
        let finalProgress = currentPlaybackProgress
        let finalDuration = duration
        let entryId = currentEntryId

        teardownRemotePlayback()
        state = .stopped
        currentURL = nil
        currentEntryId = nil

        if let entryId {
            delegate?.audioPlayerDidFinishPlaying(
                player: self,
                entryId: entryId,
                stopReason: .eof,
                progress: finalProgress,
                duration: finalDuration
            )
        }
    }

    private func handleRemotePlaybackFailure(_ error: Error) {
        let entryId = currentEntryId
        teardownRemotePlayback()
        state = .stopped
        currentURL = nil
        currentEntryId = nil

        let normalizedError = normalizePlaybackError(error)
        guard let entryId else {
            delegate?.audioPlayerUnexpectedError(player: self, error: normalizedError)
            return
        }

        handlePlaybackError(normalizedError, entryId: entryId)
    }

    private func stopLocalPlayback(notifyFinish: Bool) {
        pauseWhenPlaybackStarts = false

        let wasPlaying = state == .playing
        let currentProgress = currentPlaybackProgress
        let currentDuration = duration
        let entryId = currentEntryId

        sfbPlayer.stop()
        state = .stopped

        if notifyFinish, wasPlaying, let entryId {
            delegate?.audioPlayerDidFinishPlaying(
                player: self,
                entryId: entryId,
                stopReason: .userAction,
                progress: currentProgress,
                duration: currentDuration
            )
        }

        currentURL = nil
        currentEntryId = nil
        Logger.info("Playback stopped")
    }

    private func stopRemotePlayback(notifyFinish: Bool) {
        let wasPlaying = state == .playing
        let currentProgress = currentPlaybackProgress
        let currentDuration = duration
        let entryId = currentEntryId

        remoteStopInProgress = true
        teardownRemotePlayback()
        state = .stopped

        if notifyFinish, wasPlaying, let entryId {
            delegate?.audioPlayerDidFinishPlaying(
                player: self,
                entryId: entryId,
                stopReason: .userAction,
                progress: currentProgress,
                duration: currentDuration
            )
        }

        currentURL = nil
        currentEntryId = nil
        Logger.info("Remote playback stopped")
    }

    private func teardownRemotePlayback() {
        remoteDidStartPlaying = false
        // Cancel KVO observations (setting token to nil cancels the observation)
        avPlayerStatusObserver = nil
        avPlayerTimeControlObserver = nil
        // Remove NotificationCenter observers
        if let obs = avPlayerItemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            avPlayerItemEndObserver = nil
        }
        if let obs = avPlayerItemFailedObserver {
            NotificationCenter.default.removeObserver(obs)
            avPlayerItemFailedObserver = nil
        }
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
    }

    private func applyRemoteVolume() {
        avPlayer?.volume = currentVolume
    }

    private func redactedURLString(_ url: URL?) -> String {
        guard let url else { return "<nil>" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.queryItems = components.queryItems?.map { item in
            let lowercasedName = item.name.lowercased()
            if lowercasedName == "api_key" || lowercasedName == "x-emby-token" {
                return URLQueryItem(name: item.name, value: "REDACTED")
            }
            return item
        }

        return components.string ?? url.absoluteString
    }

    private func normalizePlaybackError(_ error: Error) -> AudioPlayerError {
        if let audioPlayerError = error as? AudioPlayerError {
            return audioPlayerError
        }
        return .engineError(error)
    }

    /// Handle playback errors
    private func handlePlaybackError(_ error: Error, entryId: AudioEntryId) {
        Logger.error("Failed to play audio: \(error)")
        state = .stopped

        delegate?.audioPlayerUnexpectedError(player: self, error: normalizePlaybackError(error))
        delegate?.audioPlayerDidFinishPlaying(
            player: self,
            entryId: entryId,
            stopReason: .error,
            progress: 0,
            duration: 0
        )
    }

    private func attemptLocalPlaybackRecovery(from error: Error) -> Bool {
        guard state == .playing, isRecoverableAudioRouteError(error) else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRouteRecoveryAttemptTime > 2 else {
            return false
        }
        lastRouteRecoveryAttemptTime = now

        if effectsAttached {
            Logger.warning("Audio route failed to reopen, retrying playback without inserted audio effects")
            teardownAudioEffects()
        } else {
            Logger.warning("Audio route failed to reopen, retrying playback by restarting the audio engine")
        }

        do {
            try sfbPlayer.play()
            state = .playing
            Logger.info("Recovered local playback after audio route change")
            return true
        } catch {
            Logger.error("Failed to recover local playback after route change: \(error)")
            return false
        }
    }

    private func isRecoverableAudioRouteError(_ error: Error) -> Bool {
        matchesRecoverableAudioRouteError(error as NSError)
    }

    private func matchesRecoverableAudioRouteError(_ error: NSError) -> Bool {
        if error.code == -12860 {
            return true
        }

        let diagnosticText = [
            error.domain,
            error.localizedDescription,
            error.localizedFailureReason,
            error.localizedRecoverySuggestion
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if diagnosticText.contains("cannot open") || diagnosticText.contains("figairplay_route") {
            return true
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return matchesRecoverableAudioRouteError(underlyingError)
        }

        return false
    }

    private func setupAudioEffects() {
        guard !effectsAttached else {
            Logger.info("Audio effects already attached")
            return
        }

        let sourceNode = sfbPlayer.sourceNode
        let mainMixer = sfbPlayer.mainMixerNode
        let format = sourceNode.outputFormat(forBus: 0)

        Logger.info("Setting up audio effects...")
        Logger.info("Source node: \(sourceNode), Format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        sfbPlayer.modifyProcessingGraph { [self] engine in
            setupStereoWidening(engine: engine)
            setupEqualizer(engine: engine)

            guard let stereoNode = stereoWideningNode, let equalizer = eqNode else {
                Logger.warning("Failed to create effect nodes")
                return
            }

            // Disconnect sourceNode from mainMixer
            engine.disconnectNodeOutput(sourceNode)

            // Connect: sourceNode -> stereoWidening -> EQ -> mainMixer
            engine.connect(sourceNode, to: stereoNode, format: format)
            engine.connect(stereoNode, to: equalizer, format: format)
            engine.connect(equalizer, to: mainMixer, format: format)

            effectsAttached = true
            Logger.info("Audio effects setup complete")
        }
    }

    private func teardownAudioEffects(using engine: AVAudioEngine? = nil) {
        guard effectsAttached || stereoWideningNode != nil || eqNode != nil else {
            return
        }

        let detachEffects = { (engine: AVAudioEngine) in
            let sourceNode = self.sfbPlayer.sourceNode
            let mainMixer = self.sfbPlayer.mainMixerNode
            let format = sourceNode.outputFormat(forBus: 0)

            engine.disconnectNodeOutput(sourceNode)

            if let oldStereoNode = self.stereoWideningNode {
                engine.detach(oldStereoNode)
                self.stereoWideningNode = nil
            }

            if let oldEQNode = self.eqNode {
                engine.detach(oldEQNode)
                self.eqNode = nil
            }

            engine.connect(sourceNode, to: mainMixer, format: format)
            self.effectsAttached = false
            Logger.info("Detached inserted audio effects and restored direct mixer path")
        }

        if let engine {
            detachEffects(engine)
        } else {
            sfbPlayer.modifyProcessingGraph { engine in
                detachEffects(engine)
            }
        }
    }

    private func setupStereoWidening(engine: AVAudioEngine) {
        let delay = AVAudioUnitDelay()
        delay.delayTime = 0.020
        delay.wetDryMix = 50
        delay.feedback = -10
        delay.lowPassCutoff = 15000
        delay.bypass = !stereoWideningEnabled

        engine.attach(delay)
        self.stereoWideningNode = delay

        Logger.info("Attached delay node (Haas effect stereo widening)")
    }

    private func setupEqualizer(engine: AVAudioEngine) {
        let eq = AVAudioUnitEQ(numberOfBands: 10)

        for (index, frequency) in eqFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = currentEQGains[index]
            band.bypass = false
        }
        eq.globalGain = preampGain
        eq.bypass = !eqEnabled

        engine.attach(eq)
        self.eqNode = eq
        Logger.info("Attached EQ node to engine")
    }

    private func calculateGainCompensation() -> Float {
        guard eqEnabled else { return 0 }

        let maxBandGain = currentEQGains.max() ?? 0

        if maxBandGain > 0 {
            // Offset max gain to prevent audio
            // distortion due to signal clipping
            return -(maxBandGain + 1.0)
        }
        return 0
    }

    private func applyEffectivePreamp() {
        let compensation = calculateGainCompensation()
        preampGain = userPreampGain + compensation

        if !effectsAttached {
            setupAudioEffects()
        }

        eqNode?.globalGain = preampGain
    }
}

// MARK: - Private Delegate Bridge

/// Internal class that bridges SFBAudioEngine delegate callbacks to PAudioPlayer
private class SFBAudioPlayerDelegateBridge: NSObject, SFBAudioEngine.AudioPlayer.Delegate {
    weak var owner: PAudioPlayer?

    init(owner: PAudioPlayer) {
        self.owner = owner
        super.init()
    }

    func audioPlayer(
        _ audioPlayer: SFBAudioEngine.AudioPlayer,
        playbackStateChanged playbackState: SFBAudioEngine.AudioPlayer.PlaybackState
    ) {
        owner?.handlePlaybackStateChanged(playbackState)
    }

    func audioPlayerEndOfAudio(_ audioPlayer: SFBAudioEngine.AudioPlayer) {
        owner?.handleEndOfAudio()
    }

    func audioPlayer(
        _ audioPlayer: SFBAudioEngine.AudioPlayer,
        encounteredError error: Error
    ) {
        owner?.handleError(error)
    }

    func audioPlayer(
        _ audioPlayer: SFBAudioEngine.AudioPlayer,
        reconfigureProcessingGraph engine: AVAudioEngine,
        with format: AVAudioFormat
    ) -> AVAudioNode {
        owner?.reconfigureAudioGraph(engine: engine, format: format) ?? engine.mainMixerNode
    }
}
