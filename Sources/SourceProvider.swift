import Foundation

enum SourceProviderError: LocalizedError {
    case unsupportedOperation(String)
    case invalidBaseURL
    case invalidResponse
    case authenticationFailed
    case missingCredential
    case missingUserID
    case malformedURL

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let message):
            return message
        case .invalidBaseURL:
            return "Invalid source server URL"
        case .invalidResponse:
            return "Invalid response from source server"
        case .authenticationFailed:
            return "Source authentication failed"
        case .missingCredential:
            return "Missing source credential"
        case .missingUserID:
            return "Missing source user identifier"
        case .malformedURL:
            return "Failed to construct source request URL"
        }
    }
}

struct PlaybackPolicy: Sendable {
    var preferredContainer: String?
    var maxBitrateKbps: Int?
    var preferDirectPlay: Bool

    static let direct = PlaybackPolicy(preferredContainer: nil, maxBitrateKbps: nil, preferDirectPlay: true)
}

struct SourceTrackSnapshot: Sendable {
    let itemID: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let composer: String?
    let genre: String?
    let year: Int?
    let duration: Double
    let trackNumber: Int?
    let totalTracks: Int?
    let discNumber: Int?
    let totalDiscs: Int?
    let bitrate: Int?
    let sampleRate: Int?
    let channels: Int?
    let codec: String?
    let bitDepth: Int?
    let fileSize: Int64?
    let format: String?
    let filename: String?
    let isFavorite: Bool
    let playCount: Int
    let lastPlayedDate: Date?
    let dateAdded: Date?
    let dateModified: Date?
    let remoteRevision: String?
    let remoteETag: String?
}

struct SourceLibraryPage: Sendable {
    let tracks: [SourceTrackSnapshot]
    let nextCursor: String?
}

struct SourcePlaybackDescriptor: Sendable {
    let streamURL: URL
    let headers: [String: String]
    let isDirectPlay: Bool
    let mediaSourceID: String?
}

enum SourcePlaybackEvent: Sendable {
    case started(itemID: String, mediaSourceID: String?, positionSeconds: Double, queueIndex: Int, queueLength: Int)
    case progress(itemID: String, mediaSourceID: String?, positionSeconds: Double, isPaused: Bool)
    case stopped(itemID: String, mediaSourceID: String?, positionSeconds: Double)
}

protocol SourceProvider: Sendable {
    var kind: SourceKind { get }

    func authenticate(
        baseURL: URL,
        username: String,
        secret: String,
        device: SourceDeviceContext
    ) async throws -> SourceAuthenticationResult

    func validate(
        account: SourceAccountRecord,
        credential: String
    ) async throws

    func fetchLibraryPage(
        account: SourceAccountRecord,
        credential: String,
        cursor: String?
    ) async throws -> SourceLibraryPage

    func resolvePlayback(
        account: SourceAccountRecord,
        credential: String,
        itemID: String,
        policy: PlaybackPolicy
    ) async throws -> SourcePlaybackDescriptor

    func setFavorite(
        account: SourceAccountRecord,
        credential: String,
        itemID: String,
        isFavorite: Bool
    ) async throws

    func reportPlayback(
        account: SourceAccountRecord,
        credential: String,
        event: SourcePlaybackEvent
    ) async
}
