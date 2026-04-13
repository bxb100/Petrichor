import Foundation
import GRDB

enum LibrarySourceKind: String, Codable, CaseIterable, Identifiable {
    case local
    case emby

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .emby:
            return "Emby"
        }
    }
}

enum NetworkConnectionType: String, Codable, CaseIterable, Identifiable {
    case http
    case https

    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }

    var defaultPort: Int {
        switch self {
        case .http:
            return 8096
        case .https:
            return 8920
        }
    }

    var urlScheme: String { rawValue }
}

enum RemoteTrackEnrichmentState: String, Codable, CaseIterable {
    case pending
    case completed
}

struct LibraryDataSource: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var kind: LibrarySourceKind
    var name: String
    var host: String
    var port: Int
    var connectionType: NetworkConnectionType
    var username: String
    var syncFavorites: Bool
    var favoritesCacheTTLSeconds: Int
    var favoritesCacheUpdatedAt: Date?
    var rollingCacheSize: Int
    var userId: String?
    var serverId: String?
    var lastSyncedAt: Date?
    var lastSyncError: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: LibrarySourceKind = .emby,
        name: String = "",
        host: String = "",
        port: Int = NetworkConnectionType.http.defaultPort,
        connectionType: NetworkConnectionType = .http,
        username: String = "",
        syncFavorites: Bool = false,
        favoritesCacheTTLSeconds: Int = 3600,
        favoritesCacheUpdatedAt: Date? = nil,
        rollingCacheSize: Int = 2,
        userId: String? = nil,
        serverId: String? = nil,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.connectionType = connectionType
        self.username = username
        self.syncFavorites = syncFavorites
        self.favoritesCacheTTLSeconds = favoritesCacheTTLSeconds
        self.favoritesCacheUpdatedAt = favoritesCacheUpdatedAt
        self.rollingCacheSize = rollingCacheSize
        self.userId = userId
        self.serverId = serverId
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static let databaseTableName = "data_sources"

    enum Columns {
        static let id = Column("id")
        static let kind = Column("kind")
        static let name = Column("name")
        static let host = Column("host")
        static let port = Column("port")
        static let connectionType = Column("connection_type")
        static let username = Column("username")
        static let syncFavorites = Column("sync_favorites")
        static let favoritesCacheTTLSeconds = Column("favorites_cache_ttl_seconds")
        static let favoritesCacheUpdatedAt = Column("favorites_cache_updated_at")
        static let rollingCacheSize = Column("rolling_cache_size")
        static let userId = Column("user_id")
        static let serverId = Column("server_id")
        static let lastSyncedAt = Column("last_synced_at")
        static let lastSyncError = Column("last_sync_error")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }

    init(row: Row) throws {
        let idString: String = row[Columns.id]
        self.id = UUID(uuidString: idString) ?? UUID()
        self.kind = LibrarySourceKind(rawValue: row[Columns.kind]) ?? .emby
        self.name = row[Columns.name]
        self.host = row[Columns.host]
        self.port = row[Columns.port]
        self.connectionType = NetworkConnectionType(rawValue: row[Columns.connectionType]) ?? .http
        self.username = row[Columns.username]
        self.syncFavorites = row[Columns.syncFavorites]
        self.favoritesCacheTTLSeconds = row[Columns.favoritesCacheTTLSeconds]
        self.favoritesCacheUpdatedAt = row[Columns.favoritesCacheUpdatedAt]
        self.rollingCacheSize = row[Columns.rollingCacheSize]
        self.userId = row[Columns.userId]
        self.serverId = row[Columns.serverId]
        self.lastSyncedAt = row[Columns.lastSyncedAt]
        self.lastSyncError = row[Columns.lastSyncError]
        self.createdAt = row[Columns.createdAt]
        self.updatedAt = row[Columns.updatedAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id.uuidString
        container[Columns.kind] = kind.rawValue
        container[Columns.name] = name
        container[Columns.host] = host
        container[Columns.port] = port
        container[Columns.connectionType] = connectionType.rawValue
        container[Columns.username] = username
        container[Columns.syncFavorites] = syncFavorites
        container[Columns.favoritesCacheTTLSeconds] = favoritesCacheTTLSeconds
        container[Columns.favoritesCacheUpdatedAt] = favoritesCacheUpdatedAt
        container[Columns.rollingCacheSize] = rollingCacheSize
        container[Columns.userId] = userId
        container[Columns.serverId] = serverId
        container[Columns.lastSyncedAt] = lastSyncedAt
        container[Columns.lastSyncError] = lastSyncError
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }
}

struct EmbyFavoriteCacheEntry: FetchableRecord, PersistableRecord {
    var sourceId: UUID
    var itemId: String
    var cachedAt: Date

    static let databaseTableName = "emby_favorite_cache"

    enum Columns {
        static let sourceId = Column("source_id")
        static let itemId = Column("item_id")
        static let cachedAt = Column("cached_at")
    }

    init(sourceId: UUID, itemId: String, cachedAt: Date = Date()) {
        self.sourceId = sourceId
        self.itemId = itemId
        self.cachedAt = cachedAt
    }

    init(row: Row) throws {
        let sourceIdString: String = row[Columns.sourceId]
        self.sourceId = UUID(uuidString: sourceIdString) ?? UUID()
        self.itemId = row[Columns.itemId]
        self.cachedAt = row[Columns.cachedAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.sourceId] = sourceId.uuidString
        container[Columns.itemId] = itemId
        container[Columns.cachedAt] = cachedAt
    }
}

enum TrackLocator {
    static let embyScheme = "emby"

    static func url(from storedValue: String) -> URL {
        if storedValue.contains("://"), let url = URL(string: storedValue) {
            return url
        }

        return URL(fileURLWithPath: storedValue)
    }

    static func storageString(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    static func makeEmbyURL(sourceId: UUID, itemId: String) -> URL {
        let escapedSource = sourceId.uuidString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceId.uuidString
        let escapedItem = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
        return URL(string: "\(embyScheme):///\(escapedSource)/\(escapedItem)")!
    }

    static func embyIdentifiers(from url: URL) -> (sourceId: String, itemId: String)? {
        guard url.scheme == embyScheme else { return nil }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }

        return (sourceId: pathComponents[0].removingPercentEncoding ?? pathComponents[0],
                itemId: pathComponents[1].removingPercentEncoding ?? pathComponents[1])
    }
}
