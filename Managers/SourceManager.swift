import Combine
import Foundation

final class SourceManager: ObservableObject {
    private static let connectOperationID = "__connect__"

    @Published private(set) var sourceAccounts: [SourceAccountRecord]
    @Published private(set) var isWorking = false
    @Published private(set) var activeOperationID: String?
    @Published var lastErrorMessage: String?

    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.sourceAccounts = databaseManager.getSourceAccounts()
    }

    var isConnecting: Bool {
        activeOperationID == Self.connectOperationID
    }

    func isWorking(for accountID: String) -> Bool {
        activeOperationID == accountID
    }

    @MainActor
    func loadAccounts() {
        sourceAccounts = databaseManager.getSourceAccounts()
    }

    @MainActor
    @discardableResult
    func connect(
        kind: SourceKind,
        baseURLString: String,
        username: String,
        secret: String,
        displayName: String
    ) async -> Bool {
        lastErrorMessage = nil

        let trimmedBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            guard kind != .local else {
                throw SourceManagerError.unsupportedSource
            }
            guard !trimmedBaseURL.isEmpty else {
                throw SourceManagerError.missingField("Server URL")
            }
            guard let baseURL = URL(string: trimmedBaseURL), baseURL.scheme != nil else {
                throw SourceManagerError.invalidServerURL
            }
            guard !trimmedUsername.isEmpty else {
                throw SourceManagerError.missingField("Username")
            }
            guard !trimmedSecret.isEmpty else {
                throw SourceManagerError.missingField("Password")
            }

            setWorkingState(isWorking: true, operationID: Self.connectOperationID)
            defer { setWorkingState(isWorking: false, operationID: nil) }

            guard let provider = await SourceRegistry.shared.provider(for: kind) else {
                throw SourceManagerError.providerUnavailable(kind)
            }

            let authenticationResult = try await provider.authenticate(
                baseURL: baseURL,
                username: trimmedUsername,
                secret: trimmedSecret,
                device: SourceDeviceContext.current
            )

            var account = authenticationResult.account
            if !trimmedDisplayName.isEmpty {
                account.displayName = trimmedDisplayName
            }

            guard !hasDuplicateAccount(account) else {
                throw SourceManagerError.duplicateAccount(account.displayName)
            }

            guard KeychainManager.save(key: account.tokenRef, value: authenticationResult.credential) else {
                throw SourceManagerError.credentialStoreFailed
            }

            do {
                try await databaseManager.saveSourceAccount(account)
            } catch {
                KeychainManager.delete(key: account.tokenRef)
                throw error
            }

            loadAccounts()
            NotificationManager.shared.addMessage(.info, "Connected \(account.displayName)")
            Logger.info("SourceManager: Connected \(account.kind.displayName) account \(account.displayName)")
            return true
        } catch {
            return handleFailure("SourceManager: Failed to connect source", error: error)
        }
    }

    @MainActor
    @discardableResult
    func validate(account: SourceAccountRecord) async -> Bool {
        lastErrorMessage = nil
        setWorkingState(isWorking: true, operationID: account.id)
        defer { setWorkingState(isWorking: false, operationID: nil) }

        do {
            guard let provider = await SourceRegistry.shared.provider(for: account.kind) else {
                throw SourceManagerError.providerUnavailable(account.kind)
            }

            let credential = try storedCredential(for: account)
            try await provider.validate(account: account, credential: credential)
            NotificationManager.shared.addMessage(.info, "\(account.displayName) is reachable")
            Logger.info("SourceManager: Verified \(account.kind.displayName) account \(account.displayName)")
            return true
        } catch {
            return handleFailure("SourceManager: Failed to validate source \(account.id)", error: error)
        }
    }

    @MainActor
    @discardableResult
    func disconnect(account: SourceAccountRecord) async -> Bool {
        lastErrorMessage = nil
        setWorkingState(isWorking: true, operationID: account.id)
        defer { setWorkingState(isWorking: false, operationID: nil) }

        do {
            try await databaseManager.deleteSourceAccount(id: account.id)

            if !KeychainManager.delete(key: account.tokenRef) {
                Logger.warning("SourceManager: Keychain cleanup failed for \(account.id)")
            }

            loadAccounts()
            NotificationManager.shared.addMessage(.info, "Disconnected \(account.displayName)")
            Logger.info("SourceManager: Disconnected \(account.kind.displayName) account \(account.displayName)")
            return true
        } catch {
            return handleFailure("SourceManager: Failed to disconnect source \(account.id)", error: error)
        }
    }

    @MainActor
    @discardableResult
    func sync(account: SourceAccountRecord) async -> Bool {
        lastErrorMessage = nil
        setWorkingState(isWorking: true, operationID: account.id)
        defer { setWorkingState(isWorking: false, operationID: nil) }

        do {
            guard let provider = await SourceRegistry.shared.provider(for: account.kind) else {
                throw SourceManagerError.providerUnavailable(account.kind)
            }

            let credential = try storedCredential(for: account)
            let folderID = try await databaseManager.ensureSourceVirtualFolder(for: account)
            let syncStartedAt = Date()

            var cursor: String?
            var inserted = 0
            var updated = 0

            while true {
                let page = try await provider.fetchLibraryPage(
                    account: account,
                    credential: credential,
                    cursor: cursor
                )

                if !page.tracks.isEmpty {
                    let batchResult = try await databaseManager.syncSourceTracksBatch(
                        account: account,
                        folderID: folderID,
                        snapshots: page.tracks,
                        syncedAt: syncStartedAt
                    )
                    inserted += batchResult.inserted
                    updated += batchResult.updated
                }

                guard let nextCursor = page.nextCursor else {
                    break
                }
                cursor = nextCursor
            }

            let removed = try await databaseManager.pruneStaleSourceTracks(
                accountID: account.id,
                syncedAt: syncStartedAt
            )
            try await databaseManager.finalizeSourceSync(accountID: account.id)
            try await databaseManager.updateSourceSyncState(
                id: account.id,
                lastSyncAt: syncStartedAt,
                syncCursor: nil
            )

            loadAccounts()
            AppCoordinator.shared?.libraryManager.scheduleLibraryReload(delay: 0.1)

            let summary = "Synced \(account.displayName): \(inserted) new, \(updated) updated, \(removed) removed"
            NotificationManager.shared.addMessage(.info, summary)
            Logger.info("SourceManager: \(summary)")
            return true
        } catch {
            return handleFailure("SourceManager: Failed to sync source \(account.id)", error: error)
        }
    }

    private func storedCredential(for account: SourceAccountRecord) throws -> String {
        guard let credential = KeychainManager.retrieve(key: account.tokenRef),
              !credential.isEmpty else {
            throw SourceManagerError.missingCredential(account.displayName)
        }

        return credential
    }

    private func hasDuplicateAccount(_ account: SourceAccountRecord) -> Bool {
        let normalizedBaseURL = normalizedBaseURLString(account.baseURL)

        return sourceAccounts.contains { existingAccount in
            existingAccount.kind == account.kind &&
            normalizedBaseURLString(existingAccount.baseURL) == normalizedBaseURL &&
            existingAccount.username.caseInsensitiveCompare(account.username) == .orderedSame
        }
    }

    private func normalizedBaseURLString(_ rawValue: String) -> String {
        var normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized
    }

    @MainActor
    private func setWorkingState(isWorking: Bool, operationID: String?) {
        self.isWorking = isWorking
        activeOperationID = operationID
    }

    @MainActor
    private func handleFailure(_ logMessage: String, error: Error) -> Bool {
        let message = error.localizedDescription
        lastErrorMessage = message
        Logger.error("\(logMessage): \(message)")
        NotificationManager.shared.addMessage(.error, message)
        return false
    }
}

private enum SourceManagerError: LocalizedError {
    case unsupportedSource
    case providerUnavailable(SourceKind)
    case missingField(String)
    case invalidServerURL
    case duplicateAccount(String)
    case credentialStoreFailed
    case missingCredential(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "Local library does not require a remote source connection"
        case .providerUnavailable(let kind):
            return "\(kind.displayName) provider is unavailable"
        case .missingField(let fieldName):
            return "\(fieldName) is required"
        case .invalidServerURL:
            return "Enter a valid server URL, including http:// or https://"
        case .duplicateAccount(let displayName):
            return "\(displayName) is already connected"
        case .credentialStoreFailed:
            return "Failed to save the source credential in Keychain"
        case .missingCredential(let displayName):
            return "Missing saved credential for \(displayName)"
        }
    }
}
