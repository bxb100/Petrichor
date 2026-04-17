import CryptoKit
import Foundation

struct NavidromeProvider: SourceProvider {
    let kind: SourceKind = .navidrome

    func authenticate(
        baseURL: URL,
        username: String,
        secret: String,
        device: SourceDeviceContext
    ) async throws -> SourceAuthenticationResult {
        let normalizedBaseURL = baseURL.standardizedSubsonicBaseURL()
        let auth = SubsonicAuth(username: username, password: secret, clientName: device.clientName)
        try await ping(baseURL: normalizedBaseURL, auth: auth)

        let sourceID = UUID().uuidString.lowercased()
        let account = SourceAccountRecord(
            id: sourceID,
            kind: .navidrome,
            displayName: username,
            baseURL: normalizedBaseURL,
            username: username,
            userID: username,
            deviceID: device.deviceID,
            tokenRef: KeychainManager.Keys.sourceCredential(for: sourceID)
        )

        return SourceAuthenticationResult(account: account, credential: secret)
    }

    func validate(
        account: SourceAccountRecord,
        credential: String
    ) async throws {
        guard let baseURL = account.resolvedBaseURL else {
            throw SourceProviderError.invalidBaseURL
        }

        let auth = SubsonicAuth(username: account.username, password: credential, clientName: About.appTitle)
        try await ping(baseURL: baseURL.standardizedSubsonicBaseURL(), auth: auth)
    }

    func fetchLibraryPage(
        account: SourceAccountRecord,
        credential: String,
        cursor: String?
    ) async throws -> SourceLibraryPage {
        guard let baseURL = account.resolvedBaseURL?.standardizedSubsonicBaseURL() else {
            throw SourceProviderError.invalidBaseURL
        }

        let auth = SubsonicAuth(username: account.username, password: credential, clientName: About.appTitle)
        let pageSize = 100
        let offset = Int(cursor ?? "0") ?? 0

        let listResponse: AlbumListResponse = try await requestSubsonicResponse(
            baseURL: baseURL,
            path: "getAlbumList2.view",
            auth: auth,
            extraQueryItems: [
                URLQueryItem(name: "type", value: "alphabeticalByArtist"),
                URLQueryItem(name: "size", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
        )

        let albums = listResponse.albumList2?.album ?? []
        if albums.isEmpty {
            return SourceLibraryPage(tracks: [], nextCursor: nil)
        }

        var tracks: [SourceTrackSnapshot] = []
        for batch in albums.chunked(into: 8) {
            let batchTracks = try await withThrowingTaskGroup(
                of: [SourceTrackSnapshot].self,
                returning: [SourceTrackSnapshot].self
            ) { group in
                for album in batch {
                    group.addTask {
                        try await fetchAlbumTracks(
                            baseURL: baseURL,
                            auth: auth,
                            albumID: album.id
                        )
                    }
                }

                var collected: [SourceTrackSnapshot] = []
                for try await albumTracks in group {
                    collected.append(contentsOf: albumTracks)
                }
                return collected
            }
            tracks.append(contentsOf: batchTracks)
        }

        let nextCursor = albums.count == pageSize ? String(offset + albums.count) : nil
        return SourceLibraryPage(tracks: tracks, nextCursor: nextCursor)
    }

    func resolvePlayback(
        account: SourceAccountRecord,
        credential: String,
        itemID: String,
        policy: PlaybackPolicy
    ) async throws -> SourcePlaybackDescriptor {
        guard let baseURL = account.resolvedBaseURL?.standardizedSubsonicBaseURL() else {
            throw SourceProviderError.invalidBaseURL
        }

        let auth = SubsonicAuth(username: account.username, password: credential, clientName: About.appTitle)
        let streamURL = try buildEndpoint(
            baseURL: baseURL,
            path: "stream.view",
            auth: auth,
            extraQueryItems: streamQueryItems(itemID: itemID, policy: policy)
        )

        return SourcePlaybackDescriptor(
            streamURL: streamURL,
            headers: [:],
            isDirectPlay: policy.preferDirectPlay,
            mediaSourceID: nil
        )
    }

    func setFavorite(
        account: SourceAccountRecord,
        credential: String,
        itemID: String,
        isFavorite: Bool
    ) async throws {
        guard let baseURL = account.resolvedBaseURL?.standardizedSubsonicBaseURL() else {
            throw SourceProviderError.invalidBaseURL
        }

        let auth = SubsonicAuth(username: account.username, password: credential, clientName: About.appTitle)
        let endpoint = isFavorite ? "star.view" : "unstar.view"
        let url = try buildEndpoint(
            baseURL: baseURL,
            path: endpoint,
            auth: auth,
            extraQueryItems: [URLQueryItem(name: "id", value: itemID)]
        )

        let (_, response) = try await AppInfo.urlSession.data(from: url)
        try ensureSubsonicHTTPStatus(response)
    }

    func reportPlayback(
        account: SourceAccountRecord,
        credential: String,
        event: SourcePlaybackEvent
    ) async {
        guard let baseURL = account.resolvedBaseURL?.standardizedSubsonicBaseURL() else {
            return
        }

        do {
            let auth = SubsonicAuth(username: account.username, password: credential, clientName: About.appTitle)

            switch event {
            case .started:
                return
            case .progress:
                return
            case .stopped(let itemID, _, let positionSeconds):
                let timestamp = Int(Date().timeIntervalSince1970 - positionSeconds)
                let url = try buildEndpoint(
                    baseURL: baseURL,
                    path: "scrobble.view",
                    auth: auth,
                    extraQueryItems: [
                        URLQueryItem(name: "id", value: itemID),
                        URLQueryItem(name: "submission", value: "true"),
                        URLQueryItem(name: "time", value: "\(timestamp)")
                    ]
                )
                let (_, response) = try await AppInfo.urlSession.data(from: url)
                try ensureSubsonicHTTPStatus(response)
            }
        } catch {
            Logger.warning("NavidromeProvider: Failed to report playback - \(error.localizedDescription)")
        }
    }

    private func ping(baseURL: URL, auth: SubsonicAuth) async throws {
        let _: EmptySubsonicResponse = try await requestSubsonicResponse(
            baseURL: baseURL,
            path: "ping.view",
            auth: auth,
            extraQueryItems: []
        )
    }

    private func fetchAlbumTracks(
        baseURL: URL,
        auth: SubsonicAuth,
        albumID: String
    ) async throws -> [SourceTrackSnapshot] {
        let response: AlbumResponse = try await requestSubsonicResponse(
            baseURL: baseURL,
            path: "getAlbum.view",
            auth: auth,
            extraQueryItems: [URLQueryItem(name: "id", value: albumID)]
        )

        guard let album = response.album else {
            return []
        }

        let songs = album.song ?? []
        let totalDiscs = songs.compactMap(\.discNumber).max()

        return songs.map { song in
            let format = song.suffix?.lowercased()
                ?? song.contentType?.components(separatedBy: "/").last?.lowercased()

            return SourceTrackSnapshot(
                itemID: song.id,
                title: song.title ?? song.id,
                artist: song.artist ?? album.artist ?? "Unknown Artist",
                album: song.album ?? album.name ?? "Unknown Album",
                albumArtist: song.albumArtist ?? album.artist,
                composer: nil,
                genre: song.genre,
                year: song.year ?? album.year,
                duration: song.duration ?? 0,
                trackNumber: song.track,
                totalTracks: songs.count,
                discNumber: song.discNumber,
                totalDiscs: totalDiscs,
                bitrate: song.bitRate,
                sampleRate: song.samplingRate,
                channels: song.channelCount,
                codec: format,
                bitDepth: nil,
                fileSize: song.size,
                format: format,
                filename: song.path?.components(separatedBy: "/").last,
                isFavorite: song.starred != nil,
                playCount: song.playCount ?? 0,
                lastPlayedDate: SubsonicDateParser.parse(song.played),
                dateAdded: SubsonicDateParser.parse(song.created),
                dateModified: nil,
                remoteRevision: song.created,
                remoteETag: nil
            )
        }
    }

    private func requestSubsonicResponse<Response: SubsonicResponsePayload>(
        baseURL: URL,
        path: String,
        auth: SubsonicAuth,
        extraQueryItems: [URLQueryItem]
    ) async throws -> Response {
        let url = try buildEndpoint(baseURL: baseURL, path: path, auth: auth, extraQueryItems: extraQueryItems)
        let (data, response) = try await AppInfo.urlSession.data(from: url)
        try ensureSubsonicHTTPStatus(response)

        let decoded = try JSONDecoder().decode(SubsonicEnvelope<Response>.self, from: data)
        guard decoded.subsonicResponse.status == "ok" else {
            throw SourceProviderError.unsupportedOperation(
                decoded.subsonicResponse.error?.message ?? "Subsonic request failed"
            )
        }

        return decoded.subsonicResponse
    }

    private func streamQueryItems(itemID: String, policy: PlaybackPolicy) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "id", value: itemID)]

        if let maxBitrateKbps = policy.maxBitrateKbps {
            items.append(URLQueryItem(name: "maxBitRate", value: "\(maxBitrateKbps)"))
        }

        if policy.preferDirectPlay {
            items.append(URLQueryItem(name: "format", value: "raw"))
        } else if let preferredContainer = policy.preferredContainer {
            items.append(URLQueryItem(name: "format", value: preferredContainer))
        }

        return items
    }

    private func buildEndpoint(
        baseURL: URL,
        path: String,
        auth: SubsonicAuth,
        extraQueryItems: [URLQueryItem]
    ) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = auth.queryItems + extraQueryItems

        guard let url = components?.url else {
            throw SourceProviderError.malformedURL
        }
        return url
    }

    private func ensureSubsonicHTTPStatus(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SourceProviderError.invalidResponse
        }
    }
}

private extension NavidromeProvider {
    protocol SubsonicResponsePayload: Decodable {
        var status: String { get }
        var error: SubsonicError? { get }
    }

    struct SubsonicEnvelope<Response: SubsonicResponsePayload>: Decodable {
        let subsonicResponse: Response

        enum CodingKeys: String, CodingKey {
            case subsonicResponse = "subsonic-response"
        }
    }

    struct SubsonicError: Decodable {
        let code: Int?
        let message: String?
    }

    struct EmptySubsonicResponse: SubsonicResponsePayload {
        let status: String
        let error: SubsonicError?
    }

    struct AlbumListResponse: SubsonicResponsePayload {
        let status: String
        let error: SubsonicError?
        let albumList2: AlbumList2?
    }

    struct AlbumList2: Decodable {
        let album: [AlbumSummary]?
    }

    struct AlbumSummary: Decodable {
        let id: String
    }

    struct AlbumResponse: SubsonicResponsePayload {
        let status: String
        let error: SubsonicError?
        let album: AlbumDetails?
    }

    struct AlbumDetails: Decodable {
        let id: String?
        let name: String?
        let artist: String?
        let year: Int?
        let song: [SongDetails]?
    }

    struct SongDetails: Decodable {
        let id: String
        let title: String?
        let artist: String?
        let album: String?
        let albumArtist: String?
        let genre: String?
        let duration: Double?
        let track: Int?
        let discNumber: Int?
        let year: Int?
        let size: Int64?
        let suffix: String?
        let contentType: String?
        let bitRate: Int?
        let samplingRate: Int?
        let channelCount: Int?
        let path: String?
        let starred: String?
        let playCount: Int?
        let played: String?
        let created: String?
    }

    struct SubsonicAuth {
        let username: String
        let password: String
        let clientName: String

        var queryItems: [URLQueryItem] {
            let salt = String(UUID().uuidString.prefix(8)).lowercased()
            let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
                .map { String(format: "%02x", $0) }
                .joined()

            return [
                URLQueryItem(name: "u", value: username),
                URLQueryItem(name: "t", value: token),
                URLQueryItem(name: "s", value: salt),
                URLQueryItem(name: "v", value: "1.16.1"),
                URLQueryItem(name: "c", value: clientName),
                URLQueryItem(name: "f", value: "json")
            ]
        }
    }
}

private enum SubsonicDateParser {
    static let formatters: [DateFormatter] = {
        let full = DateFormatter()
        full.locale = Locale(identifier: "en_US_POSIX")
        full.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"

        let seconds = DateFormatter()
        seconds.locale = Locale(identifier: "en_US_POSIX")
        seconds.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"

        let simple = DateFormatter()
        simple.locale = Locale(identifier: "en_US_POSIX")
        simple.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        return [full, seconds, simple]
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

private extension URL {
    func standardizedSubsonicBaseURL() -> URL {
        let absoluteString = absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
        let base = URL(string: absoluteString) ?? self

        if base.lastPathComponent == "rest" {
            return base
        }

        return base.appendingPathComponent("rest")
    }
}
