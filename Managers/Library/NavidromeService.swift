import CryptoKit
import Foundation

private final class NavidromeDateDecoder: @unchecked Sendable {
    private let fractionalFormatter: DateFormatter
    private let plainFormatter: DateFormatter
    private let lock = NSLock()

    init() {
        let fractionalFormatter = DateFormatter()
        fractionalFormatter.locale = Locale(identifier: "en_US_POSIX")
        fractionalFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        fractionalFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSZZZZZ"
        self.fractionalFormatter = fractionalFormatter

        let plainFormatter = DateFormatter()
        plainFormatter.locale = Locale(identifier: "en_US_POSIX")
        plainFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        plainFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        self.plainFormatter = plainFormatter
    }

    func decode(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }

        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        return plainFormatter.date(from: string)
    }
}

struct NavidromeSession: Sendable {
    let username: String
    let password: String
    let serverVersion: String?
}

private protocol NavidromeResponseStatusProviding {
    var status: String { get }
    var error: NavidromeAPIErrorPayload? { get }
}

private struct NavidromeEnvelope<Response: Decodable>: Decodable {
    let response: Response

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

private struct NavidromeAPIErrorPayload: Decodable {
    let code: Int?
    let message: String?
}

private struct NavidromePingResponse: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let serverVersion: String?
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromeAlbumListResponse: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let albumList2: NavidromeAlbumListContainer?
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromeAlbumListContainer: Decodable {
    let album: [NavidromeAlbumSummary]?
}

private struct NavidromeAlbumResponse: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let album: NavidromeAlbum?
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromeStarred2Response: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let starred2: NavidromeStarred2?
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromeEmptyResponse: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromePlayQueueResponse: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let playQueue: NavidromePlayQueue?
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromeScanStatusResponse: Decodable, NavidromeResponseStatusProviding {
    let status: String
    let scanStatus: NavidromeScanStatus?
    let error: NavidromeAPIErrorPayload?
}

private struct NavidromeStarred2: Decodable {
    let song: [NavidromeSong]?
}

struct NavidromePlayQueue: Decodable, Sendable {
    let current: String?
    let position: Int64?
    let changed: Date?
    let entry: [NavidromeSong]?
}

struct NavidromeScanStatus: Decodable, Sendable {
    let scanning: Bool?
    let count: Int?
    let lastScan: Date?
    let folderCount: Int?
}

struct NavidromeNamedValue: Decodable, Sendable {
    let id: String?
    let name: String?
}

struct NavidromeAlbumSummary: Decodable, Sendable {
    let id: String
    let name: String?
    let artist: String?
    let coverArt: String?
    let year: Int?
    let genre: String?
    let genres: [NavidromeNamedValue]?
    let created: Date?
}

struct NavidromeAlbum: Decodable, Sendable {
    let id: String
    let name: String?
    let artist: String?
    let coverArt: String?
    let year: Int?
    let genre: String?
    let genres: [NavidromeNamedValue]?
    let created: Date?
    let song: [NavidromeSong]?
}

struct NavidromeSong: Decodable, Sendable {
    let id: String
    let parent: String?
    let title: String?
    let album: String?
    let artist: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let duration: Double?
    let bitRate: Int?
    let path: String?
    let created: Date?
    let albumId: String?
    let artistId: String?
    let genre: String?
    let genres: [NavidromeNamedValue]?
    let playCount: Int?
    let starred: Date?
    let userRating: Int?
    let bpm: Int?
    let mediaType: String?
    let channelCount: Int?
    let samplingRate: Int?
    let bitDepth: Int?
    let artists: [NavidromeNamedValue]?
    let albumArtists: [NavidromeNamedValue]?
    let displayArtist: String?
    let displayAlbumArtist: String?
    let displayComposer: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parent
        case title
        case album
        case artist
        case track
        case discNumber
        case year
        case coverArt
        case size
        case contentType
        case suffix
        case duration
        case bitRate
        case path
        case created
        case albumId
        case artistId
        case genre
        case genres
        case playCount
        case starred
        case userRating
        case bpm
        case mediaType
        case channelCount
        case samplingRate
        case bitDepth
        case artists
        case albumArtists
        case displayArtist
        case displayAlbumArtist
        case displayComposer
    }
}

enum NavidromeServiceError: LocalizedError {
    case invalidBaseURL
    case invalidCredentials
    case invalidResponse
    case missingRemoteItemId
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Navidrome server address."
        case .invalidCredentials:
            return "Authentication failed. Please verify your Navidrome credentials."
        case .invalidResponse:
            return "Received an invalid response from Navidrome."
        case .missingRemoteItemId:
            return "Missing Navidrome item identifier."
        case .requestFailed(let message):
            return message
        }
    }
}

actor NavidromeService {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let clientName = "Petrichor"
    private let apiVersion = "1.16.1"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        let dateDecoder = NavidromeDateDecoder()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = dateDecoder.decode(dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Navidrome date: \(dateString)")
        }
        self.decoder = decoder
    }

    func authenticate(source: LibraryDataSource, password: String) async throws -> NavidromeSession {
        let request = try makeRequest(
            source: source,
            endpoint: "ping",
            username: source.username,
            password: password
        )
        let response: NavidromePingResponse = try await perform(request)
        return NavidromeSession(
            username: source.username,
            password: password,
            serverVersion: response.serverVersion
        )
    }

    func fetchAlbumListPage(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        offset: Int,
        size: Int
    ) async throws -> [NavidromeAlbumSummary] {
        let request = try makeRequest(
            source: source,
            endpoint: "getAlbumList2",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: [
                URLQueryItem(name: "type", value: "alphabeticalByName"),
                URLQueryItem(name: "size", value: String(size)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
        )
        let response: NavidromeAlbumListResponse = try await perform(request)
        return response.albumList2?.album ?? []
    }

    func fetchAlbum(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        albumId: String
    ) async throws -> NavidromeAlbum {
        let request = try makeRequest(
            source: source,
            endpoint: "getAlbum",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: [
                URLQueryItem(name: "id", value: albumId)
            ]
        )
        let response: NavidromeAlbumResponse = try await perform(request)
        guard let album = response.album else {
            throw NavidromeServiceError.invalidResponse
        }
        return album
    }

    func fetchFavoriteAudioItemIDs(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession
    ) async throws -> Set<String> {
        let request = try makeRequest(
            source: source,
            endpoint: "getStarred2",
            username: navidromeSession.username,
            password: navidromeSession.password
        )
        let response: NavidromeStarred2Response = try await perform(request)
        return Set((response.starred2?.song ?? []).map(\.id))
    }

    func fetchPlayQueue(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession
    ) async throws -> NavidromePlayQueue? {
        let request = try makeRequest(
            source: source,
            endpoint: "getPlayQueue",
            username: navidromeSession.username,
            password: navidromeSession.password
        )
        let response: NavidromePlayQueueResponse = try await perform(request)
        return response.playQueue
    }

    func fetchScanStatus(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession
    ) async throws -> NavidromeScanStatus? {
        let request = try makeRequest(
            source: source,
            endpoint: "getScanStatus",
            username: navidromeSession.username,
            password: navidromeSession.password
        )
        let response: NavidromeScanStatusResponse = try await perform(request)
        return response.scanStatus
    }

    func setFavorite(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        itemId: String,
        isFavorite: Bool
    ) async throws {
        let request = try makeRequest(
            source: source,
            endpoint: isFavorite ? "star" : "unstar",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: [
                URLQueryItem(name: "id", value: itemId)
            ]
        )
        let _: NavidromeEmptyResponse = try await perform(request)
    }

    func scrobble(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        itemId: String,
        submission: Bool,
        time: Date? = nil
    ) async throws {
        var queryItems = [
            URLQueryItem(name: "id", value: itemId),
            URLQueryItem(name: "submission", value: submission ? "true" : "false")
        ]

        if let time {
            let timestamp = Int64(time.timeIntervalSince1970 * 1000)
            queryItems.append(URLQueryItem(name: "time", value: String(timestamp)))
        }

        let request = try makeRequest(
            source: source,
            endpoint: "scrobble",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: queryItems
        )
        let _: NavidromeEmptyResponse = try await perform(request)
    }

    func savePlayQueue(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        queueItemIds: [String],
        currentItemId: String?,
        positionMillis: Int64?
    ) async throws {
        guard !queueItemIds.isEmpty else { return }

        var queryItems = queueItemIds.map { URLQueryItem(name: "id", value: $0) }
        if let currentItemId, !currentItemId.isEmpty {
            queryItems.append(URLQueryItem(name: "current", value: currentItemId))
        }
        if let positionMillis {
            queryItems.append(URLQueryItem(name: "position", value: String(positionMillis)))
        }

        let request = try makeRequest(
            source: source,
            endpoint: "savePlayQueue",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: queryItems
        )
        let _: NavidromeEmptyResponse = try await perform(request)
    }

    func downloadCoverArtData(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        coverArtId: String,
        size: Int = 512
    ) async throws -> Data? {
        let request = try makeRequest(
            source: source,
            endpoint: "getCoverArt",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: [
                URLQueryItem(name: "id", value: coverArtId),
                URLQueryItem(name: "size", value: String(size))
            ]
        )

        let (data, response) = try await performRaw(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavidromeServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                return nil
            }
            throw NavidromeServiceError.requestFailed("Failed to download Navidrome artwork (\(httpResponse.statusCode)).")
        }

        guard !data.isEmpty else { return nil }
        return ImageUtils.validatedImageData(from: data, source: "Navidrome/\(coverArtId)/CoverArt")
    }

    func makePlaybackURL(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        track: Track
    ) throws -> URL {
        guard let remoteItemId = track.remoteItemId ?? TrackLocator.navidromeIdentifiers(from: track.url)?.itemId else {
            throw NavidromeServiceError.missingRemoteItemId
        }

        return try buildURL(
            source: source,
            endpoint: "stream",
            username: navidromeSession.username,
            password: navidromeSession.password,
            queryItems: [
                URLQueryItem(name: "id", value: remoteItemId)
            ]
        )
    }

    func downloadAudio(
        source: LibraryDataSource,
        session navidromeSession: NavidromeSession,
        track: Track,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let remoteURL = try makePlaybackURL(source: source, session: navidromeSession, track: track)
        progressHandler(0)

        let (temporaryURL, response) = try await session.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavidromeServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NavidromeServiceError.requestFailed("Failed to cache Navidrome track (\(httpResponse.statusCode)).")
        }

        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        progressHandler(1)
        return destinationURL
    }

    private func makeRequest(
        source: LibraryDataSource,
        endpoint: String,
        username: String,
        password: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        let url = try buildURL(
            source: source,
            endpoint: endpoint,
            username: username,
            password: password,
            queryItems: queryItems
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func buildURL(
        source: LibraryDataSource,
        endpoint: String,
        username: String,
        password: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents() as URLComponents? else {
            throw NavidromeServiceError.invalidBaseURL
        }

        components.scheme = source.connectionType.urlScheme
        components.host = source.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = source.port
        components.path = "/rest/\(endpoint)"
        components.queryItems = authenticationQueryItems(username: username, password: password) + queryItems

        guard let url = components.url else {
            throw NavidromeServiceError.invalidBaseURL
        }

        return url
    }

    private func authenticationQueryItems(username: String, password: String) -> [URLQueryItem] {
        let salt = randomSalt()
        let token = md5Hash(password + salt)
        return [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    private func randomSalt(length: Int = 12) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet.randomElement() ?? "a" })
    }

    private func md5Hash(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func perform<ResponseType: Decodable & NavidromeResponseStatusProviding>(
        _ request: URLRequest
    ) async throws -> ResponseType {
        let (data, response) = try await performRaw(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavidromeServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw NavidromeServiceError.invalidCredentials
            }

            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NavidromeServiceError.requestFailed(
                message?.isEmpty == false ? message! : "Navidrome request failed with status \(httpResponse.statusCode)."
            )
        }

        do {
            let envelope = try decoder.decode(NavidromeEnvelope<ResponseType>.self, from: data)
            let payload = envelope.response
            guard payload.status.caseInsensitiveCompare("ok") == .orderedSame else {
                throw mapSubsonicError(payload.error)
            }
            return payload
        } catch let error as NavidromeServiceError {
            throw error
        } catch {
            Logger.error("Failed to decode Navidrome response: \(error)")
            throw NavidromeServiceError.invalidResponse
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .appTransportSecurityRequiresSecureConnection {
                throw NavidromeServiceError.requestFailed(
                    "HTTP connections are blocked by App Transport Security. Please restart Petrichor after updating to a build that enables HTTP Navidrome sources."
                )
            }
            throw NavidromeServiceError.requestFailed(urlError.localizedDescription)
        } catch {
            throw NavidromeServiceError.requestFailed(error.localizedDescription)
        }
    }

    private func mapSubsonicError(_ error: NavidromeAPIErrorPayload?) -> NavidromeServiceError {
        guard let error else {
            return .invalidResponse
        }

        if error.code == 40 {
            return .invalidCredentials
        }

        if let message = error.message, !message.isEmpty {
            return .requestFailed(message)
        }

        return .invalidResponse
    }
}
