import Foundation
import GRDB

extension DatabaseManager {
    func getSourceAccounts() -> [SourceAccountRecord] {
        do {
            return try dbQueue.read { db in
                try SourceAccountRecord
                    .order(SourceAccountRecord.Columns.displayName.asc)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to load source accounts: \(error)")
            return []
        }
    }

    func getSourceAccount(id: String) -> SourceAccountRecord? {
        do {
            return try dbQueue.read { db in
                try SourceAccountRecord.fetchOne(db, key: id)
            }
        } catch {
            Logger.error("Failed to load source account \(id): \(error)")
            return nil
        }
    }

    func saveSourceAccount(_ account: SourceAccountRecord) async throws {
        try await dbQueue.write { db in
            var record = account
            record.updatedAt = Date()
            try record.save(db)
        }
    }

    func deleteSourceAccount(id: String) async throws {
        try await dbQueue.write { db in
            try Folder
                .filter(Folder.Columns.sourceAccountID == id)
                .deleteAll(db)
            _ = try SourceAccountRecord.deleteOne(db, key: id)
        }

        try await cleanupOrphanedData()
    }

    func updateSourceSyncState(id: String, lastSyncAt: Date, syncCursor: String?) async throws {
        _ = try await dbQueue.write { db in
            try SourceAccountRecord
                .filter(SourceAccountRecord.Columns.id == id)
                .updateAll(
                    db,
                    SourceAccountRecord.Columns.lastSyncAt.set(to: lastSyncAt),
                    SourceAccountRecord.Columns.syncCursor.set(to: syncCursor),
                    SourceAccountRecord.Columns.updatedAt.set(to: Date())
                )
        }
    }
}
