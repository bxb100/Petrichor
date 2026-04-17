import Foundation
import GRDB

enum SourceKind: String, Codable, CaseIterable, Sendable {
    case local
    case emby
    case navidrome

    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .emby:
            return "Emby"
        case .navidrome:
            return "Navidrome"
        }
    }

    static var remoteCases: [SourceKind] {
        allCases.filter { $0 != .local }
    }
}

enum TrackAvailability: String, Codable, CaseIterable, Sendable {
    case local
    case online
    case cached
    case missing
}

struct SourceAccountRecord: Identifiable, Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "source_accounts"

    var id: String
    var kindRawValue: String
    var displayName: String
    var baseURL: String
    var username: String
    var userID: String?
    var deviceID: String
    var tokenRef: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastSyncAt: Date?
    var syncCursor: String?

    enum Columns {
        static let id = Column("id")
        static let kind = Column("kind")
        static let displayName = Column("display_name")
        static let baseURL = Column("base_url")
        static let username = Column("username")
        static let userID = Column("user_id")
        static let deviceID = Column("device_id")
        static let tokenRef = Column("token_ref")
        static let isEnabled = Column("is_enabled")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
        static let lastSyncAt = Column("last_sync_at")
        static let syncCursor = Column("sync_cursor")
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        kind: SourceKind,
        displayName: String,
        baseURL: URL,
        username: String,
        userID: String? = nil,
        deviceID: String,
        tokenRef: String,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSyncAt: Date? = nil,
        syncCursor: String? = nil
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.displayName = displayName
        self.baseURL = baseURL.absoluteString
        self.username = username
        self.userID = userID
        self.deviceID = deviceID
        self.tokenRef = tokenRef
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncAt = lastSyncAt
        self.syncCursor = syncCursor
    }

    var kind: SourceKind {
        SourceKind(rawValue: kindRawValue) ?? .local
    }

    var resolvedBaseURL: URL? {
        URL(string: baseURL)
    }

    init(row: Row) throws {
        id = row[Columns.id]
        kindRawValue = row[Columns.kind]
        displayName = row[Columns.displayName]
        baseURL = row[Columns.baseURL]
        username = row[Columns.username]
        userID = row[Columns.userID]
        deviceID = row[Columns.deviceID]
        tokenRef = row[Columns.tokenRef]
        isEnabled = row[Columns.isEnabled]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
        lastSyncAt = row[Columns.lastSyncAt]
        syncCursor = row[Columns.syncCursor]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.kind] = kindRawValue
        container[Columns.displayName] = displayName
        container[Columns.baseURL] = baseURL
        container[Columns.username] = username
        container[Columns.userID] = userID
        container[Columns.deviceID] = deviceID
        container[Columns.tokenRef] = tokenRef
        container[Columns.isEnabled] = isEnabled
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
        container[Columns.lastSyncAt] = lastSyncAt
        container[Columns.syncCursor] = syncCursor
    }
}

struct SourceAuthenticationResult: Sendable {
    let account: SourceAccountRecord
    let credential: String
}

struct SourceDeviceContext: Sendable {
    let clientName: String
    let deviceName: String
    let deviceID: String
    let appVersion: String

    static var current: SourceDeviceContext {
        let defaults = UserDefaults.standard
        let deviceIDKey = "sourceDeviceID"
        let existingDeviceID = defaults.string(forKey: deviceIDKey)
        let deviceID = existingDeviceID ?? UUID().uuidString.lowercased()

        if existingDeviceID == nil {
            defaults.set(deviceID, forKey: deviceIDKey)
        }

        return SourceDeviceContext(
            clientName: About.appTitle,
            deviceName: Host.current().localizedName ?? About.appTitle,
            deviceID: deviceID,
            appVersion: AppInfo.version
        )
    }
}

extension KeychainManager.Keys {
    static func sourceCredential(for sourceID: String) -> String {
        "org.Petrichor.source.\(sourceID).credential"
    }
}
