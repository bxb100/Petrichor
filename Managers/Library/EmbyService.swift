import Foundation

private final class EmbyDateDecoder: @unchecked Sendable {
    private let isoWithFractionalSeconds: ISO8601DateFormatter
    private let isoWithoutFractionalSeconds: ISO8601DateFormatter
    private let extendedISOFormatter: DateFormatter
    private let plainISOFormatter: DateFormatter
    private let lock = NSLock()

    init() {
        let isoWithFractionalSeconds = ISO8601DateFormatter()
        isoWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoWithFractionalSeconds = isoWithFractionalSeconds

        let isoWithoutFractionalSeconds = ISO8601DateFormatter()
        isoWithoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        self.isoWithoutFractionalSeconds = isoWithoutFractionalSeconds

        let extendedISOFormatter = DateFormatter()
        extendedISOFormatter.locale = Locale(identifier: "en_US_POSIX")
        extendedISOFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        extendedISOFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZZZZZ"
        self.extendedISOFormatter = extendedISOFormatter

        let plainISOFormatter = DateFormatter()
        plainISOFormatter.locale = Locale(identifier: "en_US_POSIX")
        plainISOFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        plainISOFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        self.plainISOFormatter = plainISOFormatter
    }

    func decode(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }

        if let date = isoWithFractionalSeconds.date(from: string) {
            return date
        }

        if let date = isoWithoutFractionalSeconds.date(from: string) {
            return date
        }

        if let date = extendedISOFormatter.date(from: string) {
            return date
        }

        return plainISOFormatter.date(from: string)
    }
}

struct EmbySession: Codable {
    let accessToken: String
    let userId: String
    let serverId: String?
}

private struct EmbyAuthenticateRequest: Encodable {
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

private struct EmbyAuthenticationResponse: Decodable {
    let user: EmbyAuthenticatedUser?
    let accessToken: String?
    let serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

private struct EmbyAuthenticatedUser: Decodable {
    let id: String?
    let serverId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverId = "ServerId"
    }
}

struct EmbyAudioItemQueryResponse: Decodable {
    let items: [EmbyAudioItem]?
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct EmbyAudioItem: Decodable {
    let id: String?
    let name: String?
    let fileName: String?
    let dateCreated: Date?
    let dateModified: Date?
    let audioCodec: String?
    let container: String?
    let mediaSources: [EmbyMediaSource]?
    let path: String?
    let genres: [String]?
    let runTimeTicks: Int64?
    let size: Int64?
    let bitrate: Int?
    let productionYear: Int?
    let premiereDate: Date?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let genreItems: [EmbyNamedValue]?
    let userData: EmbyUserData?
    let artists: [String]?
    let artistItems: [EmbyNamedValue]?
    let composers: [EmbyNamedValue]?
    let album: String?
    let albumArtist: String?
    let albumArtists: [EmbyNamedValue]?
    let mediaStreams: [EmbyMediaStream]?
    let imageTags: [String: String]?
    let primaryImageTag: String?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case fileName = "FileName"
        case dateCreated = "DateCreated"
        case dateModified = "DateModified"
        case audioCodec = "AudioCodec"
        case container = "Container"
        case mediaSources = "MediaSources"
        case path = "Path"
        case genres = "Genres"
        case runTimeTicks = "RunTimeTicks"
        case size = "Size"
        case bitrate = "Bitrate"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case genreItems = "GenreItems"
        case userData = "UserData"
        case artists = "Artists"
        case artistItems = "ArtistItems"
        case composers = "Composers"
        case album = "Album"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
        case mediaStreams = "MediaStreams"
        case imageTags = "ImageTags"
        case primaryImageTag = "PrimaryImageTag"
        case mediaType = "MediaType"
    }

    var hasPrimaryImage: Bool {
        if let primaryImageTag, !primaryImageTag.isEmpty {
            return true
        }

        if let primaryTag = imageTags?["Primary"], !primaryTag.isEmpty {
            return true
        }

        return false
    }
}

struct EmbyMediaSource: Decodable {
    let runTimeTicks: Int64?
    let size: Int64?
    let bitrate: Int?
    let container: String?
    let mediaStreams: [EmbyMediaStream]?

    enum CodingKeys: String, CodingKey {
        case runTimeTicks = "RunTimeTicks"
        case size = "Size"
        case bitrate = "Bitrate"
        case container = "Container"
        case mediaStreams = "MediaStreams"
    }
}

struct EmbyMediaStream: Decodable {
    let type: String?
    let sampleRate: Int?
    let channels: Int?
    let codec: String?
    let bitDepth: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case sampleRate = "SampleRate"
        case channels = "Channels"
        case codec = "Codec"
        case bitDepth = "BitDepth"
    }

    var isAudio: Bool {
        type?.caseInsensitiveCompare("Audio") == .orderedSame
    }
}

struct EmbyNamedValue: Decodable {
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

struct EmbyUserData: Decodable {
    let isFavorite: Bool?
    let playCount: Int?
    let lastPlayedDate: Date?

    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
        case playCount = "PlayCount"
        case lastPlayedDate = "LastPlayedDate"
    }
}

enum EmbyServiceError: LocalizedError {
    case invalidBaseURL
    case invalidCredentials
    case missingAccessToken
    case missingUserId
    case invalidResponse
    case missingRemoteItemId
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Emby server address."
        case .invalidCredentials:
            return "Authentication failed. Please verify your Emby credentials."
        case .missingAccessToken:
            return "Missing Emby access token."
        case .missingUserId:
            return "Missing Emby user id."
        case .invalidResponse:
            return "Received an invalid response from Emby."
        case .missingRemoteItemId:
            return "Missing Emby item identifier."
        case .requestFailed(let message):
            return message
        }
    }
}

actor EmbyService {
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progressHandler: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

        init(progressHandler: @escaping @Sendable (Double) -> Void) {
            self.progressHandler = progressHandler
        }

        func setContinuation(_ continuation: CheckedContinuation<(URL, URLResponse), Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        private func takeContinuation() -> CheckedContinuation<(URL, URLResponse), Error>? {
            lock.lock()
            defer { lock.unlock() }

            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard let response = downloadTask.response else {
                takeContinuation()?.resume(throwing: EmbyServiceError.invalidResponse)
                session.finishTasksAndInvalidate()
                return
            }

            progressHandler(1)
            takeContinuation()?.resume(returning: (location, response))
            session.finishTasksAndInvalidate()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard let error else { return }
            takeContinuation()?.resume(throwing: error)
            session.finishTasksAndInvalidate()
        }
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let dateDecoder: EmbyDateDecoder
    private let clientName = "Petrichor"
    private let deviceName = "macOS"
    private let deviceIdKey = "embyDeviceIdentifier"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        let dateDecoder = EmbyDateDecoder()
        self.dateDecoder = dateDecoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = dateDecoder.decode(dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Emby date: \(dateString)")
        }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func authenticate(source: LibraryDataSource, password: String) async throws -> EmbySession {
        let request = try makeRequest(
            source: source,
            path: "/Users/AuthenticateByName",
            method: "POST",
            token: nil,
            body: EmbyAuthenticateRequest(username: source.username, password: password),
            useAuthorizationHeader: true
        )

        let result: EmbyAuthenticationResponse = try await perform(request)

        guard let token = result.accessToken, !token.isEmpty else {
            throw EmbyServiceError.invalidCredentials
        }

        guard let userId = result.user?.id, !userId.isEmpty else {
            throw EmbyServiceError.missingUserId
        }

        return EmbySession(accessToken: token, userId: userId, serverId: result.serverId ?? result.user?.serverId)
    }

    func fetchAllAudioItems(source: LibraryDataSource, session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        var collectedItems: [EmbyAudioItem] = []
        var startIndex = 0
        let pageSize = DatabaseConstants.embySyncPageSize

        while true {
            let page = try await fetchAudioItemsPage(
                source: source,
                session: embySession,
                startIndex: startIndex,
                limit: pageSize
            )

            let items = page.items ?? []
            collectedItems.append(contentsOf: items)

            guard items.count == pageSize else { break }
            startIndex += pageSize
        }

        return collectedItems
    }

    func fetchFavoriteAudioItemIDs(source: LibraryDataSource, session embySession: EmbySession) async throws -> Set<String> {
        var favoriteIDs = Set<String>()
        var startIndex = 0
        let pageSize = DatabaseConstants.embySyncPageSize

        while true {
            let request = try makeRequest(
                source: source,
                path: "/Users/\(embySession.userId)/Items",
                method: "GET",
                token: embySession.accessToken,
                queryItems: [
                    URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "EnableUserData", value: "true"),
                    URLQueryItem(name: "IsFavorite", value: "true"),
                    URLQueryItem(name: "StartIndex", value: String(startIndex)),
                    URLQueryItem(name: "Limit", value: String(pageSize))
                ],
                useAuthorizationHeader: true,
                userId: embySession.userId
            )

            let response: EmbyAudioItemQueryResponse = try await perform(request)
            let items = response.items ?? []

            for item in items {
                if let itemId = item.id {
                    favoriteIDs.insert(itemId)
                }
            }

            guard items.count == pageSize else { break }
            startIndex += pageSize
        }

        return favoriteIDs
    }

    func fetchAudioItemsByIDs(
        source: LibraryDataSource,
        session embySession: EmbySession,
        itemIDs: [String]
    ) async throws -> [EmbyAudioItem] {
        guard !itemIDs.isEmpty else { return [] }

        let request = try makeRequest(
            source: source,
            path: "/Users/\(embySession.userId)/Items",
            method: "GET",
            token: embySession.accessToken,
            queryItems: [
                URLQueryItem(name: "Ids", value: itemIDs.joined(separator: ",")),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
                URLQueryItem(name: "Fields", value: "Genres,MediaSources,DateCreated,DateModified,Path,PremiereDate")
            ],
            useAuthorizationHeader: true,
            userId: embySession.userId
        )

        let response: EmbyAudioItemQueryResponse = try await perform(request)
        return response.items ?? []
    }

    func downloadPrimaryImageData(
        source: LibraryDataSource,
        session embySession: EmbySession,
        itemId: String,
        imageTag: String?
    ) async throws -> Data? {
        var queryItems = [
            URLQueryItem(name: "api_key", value: embySession.accessToken),
            URLQueryItem(name: "maxWidth", value: "512"),
            URLQueryItem(name: "quality", value: "90")
        ]
        if let imageTag, !imageTag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: imageTag))
        }

        let url = try buildURL(source: source, path: "/Items/\(itemId)/Images/Primary", queryItems: queryItems)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                return nil
            }
            throw EmbyServiceError.requestFailed("Failed to download Emby artwork (\(httpResponse.statusCode)).")
        }

        guard !data.isEmpty else { return nil }
        return ImageUtils.validatedImageData(from: data, source: "Emby/\(itemId)/Primary")
    }

    func downloadAudio(
        source: LibraryDataSource,
        session embySession: EmbySession,
        track: Track,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let remoteURL = try makeStaticStreamURL(source: source, session: embySession, track: track)
        let delegate = DownloadDelegate(progressHandler: progressHandler)
        let downloadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (temporaryURL, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            delegate.setContinuation(continuation)
            let task = downloadSession.downloadTask(with: remoteURL)
            task.resume()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw EmbyServiceError.requestFailed("Failed to cache Emby track (\(httpResponse.statusCode)).")
        }

        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    func makePlaybackURL(source: LibraryDataSource, session embySession: EmbySession, track: Track) throws -> URL {
        try makeStaticStreamURL(source: source, session: embySession, track: track)
    }

    func makeStaticStreamURL(source: LibraryDataSource, session embySession: EmbySession, track: Track) throws -> URL {
        guard let remoteItemId = track.remoteItemId ?? TrackLocator.embyIdentifiers(from: track.url)?.itemId else {
            throw EmbyServiceError.missingRemoteItemId
        }

        let trimmedContainer = track.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var queryItems = [
            URLQueryItem(name: "api_key", value: embySession.accessToken),
            URLQueryItem(name: "static", value: "true")
        ]
        if !trimmedContainer.isEmpty {
            queryItems.append(URLQueryItem(name: "container", value: trimmedContainer))
        }

        return try buildURL(
            source: source,
            path: "/Audio/\(remoteItemId)/stream",
            queryItems: queryItems
        )
    }

    func fetchAudioItemsPage(
        source: LibraryDataSource,
        session embySession: EmbySession,
        startIndex: Int,
        limit: Int,
        minDateLastSaved: Date? = nil
    ) async throws -> EmbyAudioItemQueryResponse {
        var queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "Fields", value: "Genres,MediaSources,DateCreated,DateModified,Path,PremiereDate"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        if let minDateLastSaved {
            queryItems.append(URLQueryItem(name: "MinDateLastSaved", value: iso8601Timestamp(from: minDateLastSaved)))
        }

        let request = try makeRequest(
            source: source,
            path: "/Users/\(embySession.userId)/Items",
            method: "GET",
            token: embySession.accessToken,
            queryItems: queryItems,
            useAuthorizationHeader: true,
            userId: embySession.userId
        )

        return try await perform(request)
    }

    private func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeRequest(
        source: LibraryDataSource,
        path: String,
        method: String,
        token: String?,
        queryItems: [URLQueryItem] = [],
        useAuthorizationHeader: Bool,
        userId: String? = nil
    ) throws -> URLRequest {
        try makeRequest(
            source: source,
            path: path,
            method: method,
            token: token,
            body: Optional<String>.none,
            queryItems: queryItems,
            useAuthorizationHeader: useAuthorizationHeader,
            userId: userId
        )
    }

    private func makeRequest<T: Encodable>(
        source: LibraryDataSource,
        path: String,
        method: String,
        token: String?,
        body: T? = nil,
        queryItems: [URLQueryItem] = [],
        useAuthorizationHeader: Bool,
        userId: String? = nil
    ) throws -> URLRequest {
        let url = try buildURL(source: source, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }

        if useAuthorizationHeader {
            request.setValue(
                authorizationHeader(token: token, userId: userId),
                forHTTPHeaderField: "X-Emby-Authorization"
            )
        }

        return request
    }

    private func perform<ResponseType: Decodable>(_ request: URLRequest) async throws -> ResponseType {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .appTransportSecurityRequiresSecureConnection {
                throw EmbyServiceError.requestFailed(
                    "HTTP connections are blocked by App Transport Security. Please restart Petrichor after updating to a build that enables HTTP Emby sources."
                )
            }

            throw EmbyServiceError.requestFailed(urlError.localizedDescription)
        } catch {
            throw EmbyServiceError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw EmbyServiceError.invalidCredentials
            }

            let serverMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EmbyServiceError.requestFailed(serverMessage?.isEmpty == false ? serverMessage! : "Emby request failed with status \(httpResponse.statusCode).")
        }

        do {
            return try decoder.decode(ResponseType.self, from: data)
        } catch {
            Logger.error("Failed to decode Emby response: \(error)")
            throw EmbyServiceError.invalidResponse
        }
    }

    private func buildURL(source: LibraryDataSource, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents() as URLComponents? else {
            throw EmbyServiceError.invalidBaseURL
        }

        components.scheme = source.connectionType.urlScheme
        components.host = source.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = source.port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw EmbyServiceError.invalidBaseURL
        }

        return url
    }

    private func authorizationHeader(token: String?, userId: String?) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let deviceId = persistentDeviceID()

        var components = [
            "Client=\"\(clientName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(version)\""
        ]

        if let userId, !userId.isEmpty {
            components.insert("UserId=\"\(userId)\"", at: 0)
        }

        if let token, !token.isEmpty {
            components.append("Token=\"\(token)\"")
        }

        return "Emby \(components.joined(separator: ", "))"
    }

    private func persistentDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }

        let newValue = UUID().uuidString
        defaults.set(newValue, forKey: deviceIdKey)
        return newValue
    }

}
