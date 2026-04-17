import Foundation

struct EmbyProvider: SourceProvider {
    let kind: SourceKind = .emby

    func authenticate(
        baseURL: URL,
        username: String,
        secret: String,
        device: SourceDeviceContext
    ) async throws -> SourceAuthenticationResult {
        let normalizedBaseURL = baseURL.standardizedSourceBaseURL()
        let requestURL = normalizedBaseURL.appendingPathComponent("Users/AuthenticateByName")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(device: device, userID: nil, token: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONEncoder().encode(AuthenticateUserRequest(username: username, pw: secret))

        let (data, response) = try await AppInfo.urlSession.data(for: request)
        try ensureSuccessfulStatus(response)

        let result = try JSONDecoder().decode(AuthenticationResult.self, from: data)
        guard let token = result.accessToken, !token.isEmpty else {
            throw SourceProviderError.authenticationFailed
        }

        let sourceID = UUID().uuidString.lowercased()
        let account = SourceAccountRecord(
            id: sourceID,
            kind: .emby,
            displayName: result.user.name ?? username,
            baseURL: normalizedBaseURL,
            username: username,
            userID: result.user.id,
            deviceID: device.deviceID,
            tokenRef: KeychainManager.Keys.sourceCredential(for: sourceID)
        )

        return SourceAuthenticationResult(account: account, credential: token)
    }

    func validate(
        account: SourceAccountRecord,
        credential: String
    ) async throws {
        guard let baseURL = account.resolvedBaseURL else {
            throw SourceProviderError.invalidBaseURL
        }

        let requestURL = baseURL.standardizedSourceBaseURL().appendingPathComponent("System/Info")
        var request = URLRequest(url: requestURL)
        request.setValue(credential, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(
            authorizationHeader(
                device: SourceDeviceContext(
                    clientName: About.appTitle,
                    deviceName: About.appTitle,
                    deviceID: account.deviceID,
                    appVersion: AppInfo.version
                ),
                userID: account.userID,
                token: credential
            ),
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let (_, response) = try await AppInfo.urlSession.data(for: request)
        try ensureSuccessfulStatus(response)
    }

    func fetchLibraryPage(
        account: SourceAccountRecord,
        credential: String,
        cursor: String?
    ) async throws -> SourceLibraryPage {
        guard let baseURL = account.resolvedBaseURL?.standardizedSourceBaseURL(),
              let userID = account.userID else {
            throw SourceProviderError.missingUserID
        }

        let pageSize = 200
        let startIndex = Int(cursor ?? "0") ?? 0

        var components = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userID)/Items"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "MediaTypes", value: "Audio"),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(pageSize)"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Path,Genres,MediaSources,MediaStreams,DateCreated")
        ]

        guard let requestURL = components?.url else {
            throw SourceProviderError.malformedURL
        }

        var request = URLRequest(url: requestURL)
        request.setValue(credential, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(
            authorizationHeader(
                device: SourceDeviceContext(
                    clientName: About.appTitle,
                    deviceName: About.appTitle,
                    deviceID: account.deviceID,
                    appVersion: AppInfo.version
                ),
                userID: account.userID,
                token: credential
            ),
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let (data, response) = try await AppInfo.urlSession.data(for: request)
        try ensureSuccessfulStatus(response)

        let decoder = JSONDecoder()
        let result = try decoder.decode(LibraryItemsResponse.self, from: data)
        let tracks = result.items.map { item in
            item.asSnapshot()
        }

        let nextCursor: String?
        if startIndex + result.items.count < (result.totalRecordCount ?? 0) {
            nextCursor = String(startIndex + result.items.count)
        } else {
            nextCursor = nil
        }

        return SourceLibraryPage(tracks: tracks, nextCursor: nextCursor)
    }

    func resolvePlayback(
        account: SourceAccountRecord,
        credential: String,
        itemID: String,
        policy: PlaybackPolicy
    ) async throws -> SourcePlaybackDescriptor {
        guard let baseURL = account.resolvedBaseURL?.standardizedSourceBaseURL(),
              let userID = account.userID else {
            throw SourceProviderError.missingUserID
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("Audio/\(itemID)/stream.\(policy.preferredContainer ?? "mp3")"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = playbackQueryItems(
            userID: userID,
            deviceID: account.deviceID,
            credential: credential,
            policy: policy
        )

        guard let streamURL = components?.url else {
            throw SourceProviderError.malformedURL
        }

        return SourcePlaybackDescriptor(
            streamURL: streamURL,
            headers: [
                "X-Emby-Token": credential,
                "X-Emby-Authorization": authorizationHeader(
                    device: SourceDeviceContext(
                        clientName: About.appTitle,
                        deviceName: About.appTitle,
                        deviceID: account.deviceID,
                        appVersion: AppInfo.version
                    ),
                    userID: account.userID,
                    token: credential
                )
            ],
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
        guard let baseURL = account.resolvedBaseURL?.standardizedSourceBaseURL(),
              let userID = account.userID else {
            throw SourceProviderError.missingUserID
        }

        let url = baseURL.appendingPathComponent("Users/\(userID)/FavoriteItems/\(itemID)")
        var request = URLRequest(url: url)
        request.httpMethod = isFavorite ? "POST" : "DELETE"
        request.setValue(credential, forHTTPHeaderField: "X-Emby-Token")

        let (_, response) = try await AppInfo.urlSession.data(for: request)
        try ensureSuccessfulStatus(response)
    }

    func reportPlayback(
        account: SourceAccountRecord,
        credential: String,
        event: SourcePlaybackEvent
    ) async {
        guard let baseURL = account.resolvedBaseURL?.standardizedSourceBaseURL() else {
            return
        }

        do {
            let request = try playbackRequest(baseURL: baseURL, credential: credential, event: event)
            let (_, response) = try await AppInfo.urlSession.data(for: request)
            try ensureSuccessfulStatus(response)
        } catch {
            Logger.warning("EmbyProvider: Failed to report playback - \(error.localizedDescription)")
        }
    }

    private func playbackRequest(
        baseURL: URL,
        credential: String,
        event: SourcePlaybackEvent
    ) throws -> URLRequest {
        let endpoint: String
        let payload: PlaybackEventPayload

        switch event {
        case .started(let itemID, let mediaSourceID, let positionSeconds, let queueIndex, let queueLength):
            endpoint = "Sessions/Playing"
            payload = PlaybackEventPayload(
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                positionTicks: positionSeconds.ticks,
                isPaused: false,
                queueIndex: queueIndex,
                queueLength: queueLength,
                eventName: nil
            )
        case .progress(let itemID, let mediaSourceID, let positionSeconds, let isPaused):
            endpoint = "Sessions/Playing/Progress"
            payload = PlaybackEventPayload(
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                positionTicks: positionSeconds.ticks,
                isPaused: isPaused,
                queueIndex: 0,
                queueLength: 0,
                eventName: isPaused ? "Pause" : "TimeUpdate"
            )
        case .stopped(let itemID, let mediaSourceID, let positionSeconds):
            endpoint = "Sessions/Playing/Stopped"
            payload = PlaybackEventPayload(
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                positionTicks: positionSeconds.ticks,
                isPaused: false,
                queueIndex: 0,
                queueLength: 0,
                eventName: nil
            )
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential, forHTTPHeaderField: "X-Emby-Token")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func playbackQueryItems(
        userID: String,
        deviceID: String,
        credential: String,
        policy: PlaybackPolicy
    ) -> [URLQueryItem] {
        var queryItems = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "api_key", value: credential),
            URLQueryItem(name: "PlaySessionId", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "static", value: policy.preferDirectPlay ? "true" : "false")
        ]

        if let preferredContainer = policy.preferredContainer {
            queryItems.append(URLQueryItem(name: "Container", value: preferredContainer))
            queryItems.append(URLQueryItem(name: "AudioCodec", value: preferredContainer))
        }

        if let maxBitrateKbps = policy.maxBitrateKbps {
            queryItems.append(URLQueryItem(name: "AudioBitrate", value: "\(maxBitrateKbps * 1000)"))
        }

        return queryItems
    }

    private func authorizationHeader(device: SourceDeviceContext, userID: String?, token: String?) -> String {
        var parts = [
            "Client=\"\(device.clientName)\"",
            "Device=\"\(device.deviceName)\"",
            "DeviceId=\"\(device.deviceID)\"",
            "Version=\"\(device.appVersion)\""
        ]

        if let userID, !userID.isEmpty {
            parts.insert("UserId=\"\(userID)\"", at: 0)
        }

        if let token, !token.isEmpty {
            parts.append("Token=\"\(token)\"")
        }

        return "Emby " + parts.joined(separator: ", ")
    }

    private func ensureSuccessfulStatus(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SourceProviderError.invalidResponse
        }
    }
}

private extension EmbyProvider {
    struct AuthenticateUserRequest: Encodable {
        let username: String
        let pw: String

        enum CodingKeys: String, CodingKey {
            case username = "Username"
            case pw = "Pw"
        }
    }

    struct AuthenticationResult: Decodable {
        let accessToken: String?
        let user: AuthenticatedUser

        enum CodingKeys: String, CodingKey {
            case accessToken = "AccessToken"
            case user = "User"
        }
    }

    struct AuthenticatedUser: Decodable {
        let id: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
        }
    }

    struct LibraryItemsResponse: Decodable {
        let items: [LibraryAudioItem]
        let totalRecordCount: Int?

        enum CodingKeys: String, CodingKey {
            case items = "Items"
            case totalRecordCount = "TotalRecordCount"
        }
    }

    struct LibraryAudioItem: Decodable {
        let id: String
        let name: String?
        let path: String?
        let album: String?
        let albumArtist: String?
        let albumArtists: [NameIdPair]?
        let artists: [String]?
        let artistItems: [NameIdPair]?
        let genres: [String]?
        let runTimeTicks: Int64?
        let productionYear: Int?
        let indexNumber: Int?
        let parentIndexNumber: Int?
        let userData: LibraryUserData?
        let dateCreated: String?
        let mediaSources: [LibraryMediaSource]?
        let mediaStreams: [LibraryMediaStream]?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case path = "Path"
            case album = "Album"
            case albumArtist = "AlbumArtist"
            case albumArtists = "AlbumArtists"
            case artists = "Artists"
            case artistItems = "ArtistItems"
            case genres = "Genres"
            case runTimeTicks = "RunTimeTicks"
            case productionYear = "ProductionYear"
            case indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber"
            case userData = "UserData"
            case dateCreated = "DateCreated"
            case mediaSources = "MediaSources"
            case mediaStreams = "MediaStreams"
        }

        func asSnapshot() -> SourceTrackSnapshot {
            let artistNames = artists ?? artistItems?.map(\.name)
            let resolvedArtist = artistNames?.joined(separator: "; ")
                ?? albumArtist
                ?? albumArtists?.first?.name
                ?? "Unknown Artist"
            let resolvedAlbum = album ?? "Unknown Album"
            let audioStream = mediaStreams?.first(where: { ($0.type ?? "Audio").caseInsensitiveCompare("Audio") == .orderedSame })
            let mediaSource = mediaSources?.first
            let resolvedFilename = path.map { URL(fileURLWithPath: $0).lastPathComponent }
            let resolvedFormat = mediaSource?.container
                ?? resolvedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }

            return SourceTrackSnapshot(
                itemID: id,
                title: name ?? resolvedFilename ?? id,
                artist: resolvedArtist,
                album: resolvedAlbum,
                albumArtist: albumArtist ?? albumArtists?.first?.name,
                composer: nil,
                genre: genres?.joined(separator: "; "),
                year: productionYear,
                duration: Double(runTimeTicks ?? 0) / 10_000_000,
                trackNumber: indexNumber,
                totalTracks: nil,
                discNumber: parentIndexNumber,
                totalDiscs: nil,
                bitrate: audioStream?.bitRate ?? mediaSource?.bitrate,
                sampleRate: audioStream?.sampleRate,
                channels: audioStream?.channels,
                codec: audioStream?.codec,
                bitDepth: audioStream?.bitDepth,
                fileSize: mediaSource?.size,
                format: resolvedFormat,
                filename: resolvedFilename,
                isFavorite: userData?.isFavorite ?? false,
                playCount: userData?.playCount ?? 0,
                lastPlayedDate: ISO8601DateParser.parse(userData?.lastPlayedDate),
                dateAdded: ISO8601DateParser.parse(dateCreated),
                dateModified: nil,
                remoteRevision: mediaSource?.id ?? dateCreated,
                remoteETag: mediaSource?.eTag
            )
        }
    }

    struct NameIdPair: Decodable {
        let name: String

        enum CodingKeys: String, CodingKey {
            case name = "Name"
        }
    }

    struct LibraryUserData: Decodable {
        let isFavorite: Bool?
        let playCount: Int?
        let lastPlayedDate: String?

        enum CodingKeys: String, CodingKey {
            case isFavorite = "IsFavorite"
            case playCount = "PlayCount"
            case lastPlayedDate = "LastPlayedDate"
        }
    }

    struct LibraryMediaSource: Decodable {
        let id: String?
        let eTag: String?
        let container: String?
        let size: Int64?
        let bitrate: Int?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case eTag = "ETag"
            case container = "Container"
            case size = "Size"
            case bitrate = "Bitrate"
        }
    }

    struct LibraryMediaStream: Decodable {
        let type: String?
        let codec: String?
        let bitRate: Int?
        let channels: Int?
        let sampleRate: Int?
        let bitDepth: Int?

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case codec = "Codec"
            case bitRate = "BitRate"
            case channels = "Channels"
            case sampleRate = "SampleRate"
            case bitDepth = "BitDepth"
        }
    }

    struct PlaybackEventPayload: Encodable {
        let itemID: String
        let mediaSourceID: String?
        let positionTicks: Int64
        let isPaused: Bool
        let queueIndex: Int
        let queueLength: Int
        let eventName: String?

        enum CodingKeys: String, CodingKey {
            case itemID = "ItemId"
            case mediaSourceID = "MediaSourceId"
            case positionTicks = "PositionTicks"
            case isPaused = "IsPaused"
            case queueIndex = "PlaylistIndex"
            case queueLength = "PlaylistLength"
            case eventName = "EventName"
            case canSeek = "CanSeek"
            case queueableMediaTypes = "QueueableMediaTypes"
            case playMethod = "PlayMethod"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(itemID, forKey: .itemID)
            try container.encodeIfPresent(mediaSourceID, forKey: .mediaSourceID)
            try container.encode(positionTicks, forKey: .positionTicks)
            try container.encode(isPaused, forKey: .isPaused)
            try container.encode(queueIndex, forKey: .queueIndex)
            try container.encode(queueLength, forKey: .queueLength)
            try container.encodeIfPresent(eventName, forKey: .eventName)
            try container.encode(true, forKey: .canSeek)
            try container.encode(["Audio"], forKey: .queueableMediaTypes)
            try container.encode("DirectPlay", forKey: .playMethod)
        }
    }
}

private extension Double {
    var ticks: Int64 {
        Int64((self * 10_000_000).rounded())
    }
}

private enum ISO8601DateParser {
    static let formatters: [ISO8601DateFormatter] = {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return [fractional, standard]
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
    func standardizedSourceBaseURL() -> URL {
        let absoluteString = absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
        return URL(string: absoluteString) ?? self
    }
}
