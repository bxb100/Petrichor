//
// DatabaseMigration.swift
//
// This file contains the database migration infrastructure for Petrichor
// using GRDB's built-in migration system.
//

import Foundation
import GRDB

/// Manages database migrations using GRDB's built-in migration system
enum DatabaseMigrator {
    /// Creates and configures the database migrator with all migrations
    static func setupMigrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()
        
        // MARK: - Initial Schema Migration
        migrator.registerMigration("v1_initial_schema") { db in
            // Check if this is a fresh database by looking for core tables
            let tracksExist = try db.tableExists("tracks")
            let foldersExist = try db.tableExists("folders")
            let artistsExist = try db.tableExists("artists")
            
            let tablesExist = tracksExist || foldersExist || artistsExist
            
            if !tablesExist {
                // Fresh database - create initial schema using static setup methods
                try DatabaseManager.setupDatabaseSchema(in: db)
            } else {
                // Existing database - this is our baseline
                Logger.info("Existing database detected, marking as v1 baseline")
            }
        }
        
        migrator.registerMigration("v2_add_folder_content_hash") { db in
            try db.alter(table: "folders") { t in
                t.add(column: "shasum_hash", .text)
            }
            Logger.info("Added shasum_hash column to folders table")
        }
        
        migrator.registerMigration("v3_add_category_query_indices") { db in
            // Composite index for track_artists queries (role + artist_id for faster joins)
            try db.createIndexIfNotExists(
                name: "idx_track_artists_role_artist",
                table: "track_artists",
                columns: ["role", "artist_id", "track_id"]
            )
            
            // Composite indices for duplicate-aware queries
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_artist", table: "tracks", columns: ["is_duplicate", "artist"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_album_artist", table: "tracks", columns: ["is_duplicate", "album_artist"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_composer", table: "tracks", columns: ["is_duplicate", "composer"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_genre", table: "tracks", columns: ["is_duplicate", "genre"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_year", table: "tracks", columns: ["is_duplicate", "year"])
            
            // Composite index for album_artists primary artist lookups
            try db.createIndexIfNotExists(
                name: "idx_album_artists_primary",
                table: "album_artists",
                columns: ["role", "position", "album_id", "artist_id"]
            )
            
            // Entity query optimization indices
            try db.createIndexIfNotExists(name: "idx_artists_name_normalized", table: "artists", columns: ["name", "normalized_name"])
            try db.createIndexIfNotExists(
                name: "idx_tracks_album_id_duplicate",
                table: "tracks",
                columns: ["album_id", "is_duplicate", "disc_number", "track_number"]
            )
            try db.createIndexIfNotExists(
                name: "idx_tracks_album_name_artist",
                table: "tracks",
                columns: ["album", "album_artist", "is_duplicate", "disc_number", "track_number"]
            )
            
            Logger.info("Created all indices")
            
            // Recalculate artist track counts with updated scope
            Logger.info("Recalculating artist track counts with updated scope...")
            
            let artistIds = try Artist
                .select(Artist.Columns.id, as: Int64.self)
                .fetchAll(db)
            
            var updatedCount = 0
            for artistId in artistIds {
                let trackCount = try TrackArtist
                    .joining(required: TrackArtist.track.filter(Track.Columns.isDuplicate == false))
                    .filter(TrackArtist.Columns.artistId == artistId)
                    .filter(TrackArtist.Columns.role == TrackArtist.Role.artist)
                    .select(TrackArtist.Columns.trackId, as: Int64.self)
                    .distinct()
                    .fetchCount(db)
                
                try db.execute(
                    sql: "UPDATE artists SET total_tracks = ? WHERE id = ?",
                    arguments: [trackCount, artistId]
                )
                updatedCount += 1
            }
            
            Logger.info("v3_add_category_query_indices migration completed")
        }
        
        migrator.registerMigration("v4_rebuild_fts_with_unicode61_tokenizer") { db in
            Logger.info("Rebuilding FTS table with unicode tokenization without porter stemming...")
            
            // Drop existing FTS triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_delete")
            
            // Drop existing FTS table
            try db.execute(sql: "DROP TABLE IF EXISTS tracks_fts")
            
            // Recreate FTS table with unicode61 tokenizer without porter stemming
            try DatabaseManager.createFTSTable(in: db)
            
            Logger.info("v4_rebuild_fts_with_unicode61_tokenizer migration completed")
        }
        
        migrator.registerMigration("v5_add_lossless_column") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "lossless", .boolean)
            }
            Logger.info("v5_add_lossless_column migration completed")
        }
        
        migrator.registerMigration("v6_update_most_played_criteria") { db in
            try db.execute(
                sql: """
                    UPDATE playlists
                    SET smart_criteria = REPLACE(smart_criteria, '"condition":"greaterThan"', '"condition":"greaterThanOrEqual"')
                    WHERE name = ? AND type = 'smart'
                    """,
                arguments: [DefaultPlaylists.mostPlayed]
            )
            Logger.info("v6_update_most_played_criteria migration completed")
        }

        migrator.registerMigration("v7_create_background_migrations_table") { db in
            try db.create(table: "background_migrations") { t in
                t.column("identifier", .text).primaryKey()
                t.column("completed_at", .datetime)
                t.column("progress", .text)
                t.column("resumable", .boolean).defaults(to: true)
            }
            Logger.info("v7_create_background_migrations_table migration completed")
        }
        
        migrator.registerMigration("v8_convert_artwork_to_heic") { db in
            try db.execute(
                sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                arguments: ["v8_background_convert_artwork_to_heic", true]
            )
            Logger.info("v8_convert_artwork_to_heic: flagged for background artwork conversion")
        }
        
        migrator.registerMigration("v9_rebuild_artist_associations") { db in
            try db.execute(
                sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                arguments: ["v9_background_rebuild_artist_associations", true]
            )
            Logger.info("v9_rebuild_artist_associations: flagged for background artist rebuild")
        }

        migrator.registerMigration("v10_add_remote_data_sources_support") { db in
            try DatabaseManager.createDataSourcesTable(in: db)
            try DatabaseManager.createEmbyFavoriteCacheTable(in: db)

            let trackColumnNames = try Set(db.columns(in: "tracks").map(\.name))
            let hasRemoteSourceColumns = Set(["source_id", "source_kind", "remote_item_id"]).isSubset(of: trackColumnNames)
            let referencesTemporaryTracksTable = try tracksSchemaReferencesTemporaryTable(db)

            if hasRemoteSourceColumns && !referencesTemporaryTracksTable {
                Logger.info("v10_add_remote_data_sources_support skipped: tracks schema already supports remote sources")
                return
            }

            try rebuildTracksTableForRemoteSourcesSupport(
                in: db,
                preserveExistingRemoteColumns: hasRemoteSourceColumns
            )

            Logger.info("v10_add_remote_data_sources_support migration completed")
        }

        migrator.registerMigration("v11_repair_tracks_schema_referencing_tracks_tmp") { db in
            guard try tracksSchemaReferencesTemporaryTable(db) else {
                Logger.info("v11_repair_tracks_schema_referencing_tracks_tmp skipped: no tracks_tmp reference found")
                return
            }

            try rebuildTracksTableForRemoteSourcesSupport(
                in: db,
                preserveExistingRemoteColumns: true
            )

            Logger.info("v11_repair_tracks_schema_referencing_tracks_tmp migration completed")
        }

        migrator.registerMigration("v12_add_remote_enrichment_state") { db in
            try db.addColumnIfNotExists(
                table: "tracks",
                column: "remote_enrichment_state",
                type: .text,
                defaultValue: RemoteTrackEnrichmentState.completed.rawValue,
                notNull: true
            )
            try db.createIndexIfNotExists(
                name: "idx_tracks_source_enrichment_state",
                table: "tracks",
                columns: ["source_id", "remote_enrichment_state"]
            )
            Logger.info("v12_add_remote_enrichment_state migration completed")
        }

        // MARK: - Future Migrations
        // Add new migrations here as: migrator.registerMigration("v13_description") { db in ... }
        
        return migrator
    }
    
    /// Apply all pending migrations to the database
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        let migrator = setupMigrator()
        try migrator.migrate(dbQueue)
        
        Logger.info("Database migrations completed")
    }
    
    /// Check if there are unapplied migrations
    static func hasUnappliedMigrations(_ dbQueue: DatabaseQueue) -> Bool {
        do {
            let migrator = setupMigrator()
            return try dbQueue.read { db in
                try migrator.hasBeenSuperseded(db)
            }
        } catch {
            Logger.error("Failed to check migration status: \(error)")
            return false
        }
    }
    
    /// Get list of applied migrations
    static func appliedMigrations(_ dbQueue: DatabaseQueue) -> [String] {
        // Return empty array for now - can be implemented if needed
        []
    }
}

private extension DatabaseMigrator {
    static func tracksSchemaReferencesTemporaryTable(_ db: Database) throws -> Bool {
        let trackSchemaSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tracks'"
        ) ?? ""

        if trackSchemaSQL.localizedCaseInsensitiveContains("tracks_tmp") {
            return true
        }

        let foreignKeyRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(tracks)")
        for row in foreignKeyRows {
            let referencedTable: String = row["table"]
            if referencedTable == "tracks_tmp" {
                return true
            }
        }

        return false
    }

    static func rebuildTracksTableForRemoteSourcesSupport(
        in db: Database,
        preserveExistingRemoteColumns: Bool
    ) throws {
        let existingTrackColumnNames = try Set(db.columns(in: "tracks").map(\.name))
        let hasEnrichmentStateColumn = existingTrackColumnNames.contains("remote_enrichment_state")

        try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_insert")
        try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_update")
        try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_delete")
        try db.execute(sql: "DROP TABLE IF EXISTS tracks_fts")
        try db.execute(sql: "DROP TABLE IF EXISTS tracks_rebuild")

        try db.create(table: "tracks_rebuild") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("folder_id", .integer).references("folders", onDelete: .cascade)
            t.column("source_id", .text).references("data_sources", column: "id", onDelete: .cascade)
            t.column("source_kind", .text).notNull().defaults(to: LibrarySourceKind.local.rawValue)
            t.column("remote_item_id", .text)
            t.column("remote_enrichment_state", .text).notNull().defaults(to: RemoteTrackEnrichmentState.completed.rawValue)
            t.column("album_id", .integer).references("albums", onDelete: .setNull)
            t.column("path", .text).notNull().unique()
            t.column("filename", .text).notNull()
            t.column("title", .text)
            t.column("artist", .text)
            t.column("album", .text)
            t.column("composer", .text)
            t.column("genre", .text)
            t.column("year", .text)
            t.column("duration", .double).check { $0 >= 0 }
            t.column("format", .text)
            t.column("file_size", .integer)
            t.column("date_added", .datetime).notNull()
            t.column("date_modified", .datetime)
            t.column("track_artwork_data", .blob)
            t.column("is_favorite", .boolean).notNull().defaults(to: false)
            t.column("play_count", .integer).notNull().defaults(to: 0)
            t.column("last_played_date", .datetime)
            t.column("is_duplicate", .boolean).notNull().defaults(to: false)
            t.column("primary_track_id", .integer).references("tracks", column: "id", onDelete: .setNull)
            t.column("duplicate_group_id", .text)
            t.column("album_artist", .text)
            t.column("track_number", .integer)
            t.column("total_tracks", .integer)
            t.column("disc_number", .integer)
            t.column("total_discs", .integer)
            t.column("rating", .integer).check { $0 == nil || ($0 >= 0 && $0 <= 5) }
            t.column("compilation", .boolean).defaults(to: false)
            t.column("release_date", .text)
            t.column("original_release_date", .text)
            t.column("bpm", .integer)
            t.column("media_type", .text)
            t.column("bitrate", .integer).check { $0 == nil || $0 > 0 }
            t.column("sample_rate", .integer)
            t.column("channels", .integer)
            t.column("codec", .text)
            t.column("bit_depth", .integer)
            t.column("lossless", .boolean)
            t.column("sort_title", .text)
            t.column("sort_artist", .text)
            t.column("sort_album", .text)
            t.column("sort_album_artist", .text)
            t.column("extended_metadata", .text)
        }

        if preserveExistingRemoteColumns {
            if hasEnrichmentStateColumn {
                try db.execute(
                    sql: """
                        INSERT INTO tracks_rebuild (
                            id, folder_id, source_id, source_kind, remote_item_id, remote_enrichment_state, album_id, path, filename, title, artist,
                            album, composer, genre, year, duration, format, file_size, date_added, date_modified,
                            track_artwork_data, is_favorite, play_count, last_played_date, is_duplicate,
                            primary_track_id, duplicate_group_id, album_artist, track_number, total_tracks,
                            disc_number, total_discs, rating, compilation, release_date, original_release_date,
                            bpm, media_type, bitrate, sample_rate, channels, codec, bit_depth, lossless,
                            sort_title, sort_artist, sort_album, sort_album_artist, extended_metadata
                        )
                        SELECT
                            id, folder_id, source_id, source_kind, remote_item_id, remote_enrichment_state, album_id, path, filename, title, artist,
                            album, composer, genre, year, duration, format, file_size, date_added, date_modified,
                            track_artwork_data, is_favorite, play_count, last_played_date, is_duplicate,
                            primary_track_id, duplicate_group_id, album_artist, track_number, total_tracks,
                            disc_number, total_discs, rating, compilation, release_date, original_release_date,
                            bpm, media_type, bitrate, sample_rate, channels, codec, bit_depth, lossless,
                            sort_title, sort_artist, sort_album, sort_album_artist, extended_metadata
                        FROM tracks
                    """
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO tracks_rebuild (
                            id, folder_id, source_id, source_kind, remote_item_id, remote_enrichment_state, album_id, path, filename, title, artist,
                            album, composer, genre, year, duration, format, file_size, date_added, date_modified,
                            track_artwork_data, is_favorite, play_count, last_played_date, is_duplicate,
                            primary_track_id, duplicate_group_id, album_artist, track_number, total_tracks,
                            disc_number, total_discs, rating, compilation, release_date, original_release_date,
                            bpm, media_type, bitrate, sample_rate, channels, codec, bit_depth, lossless,
                            sort_title, sort_artist, sort_album, sort_album_artist, extended_metadata
                        )
                        SELECT
                            id, folder_id, source_id, source_kind, remote_item_id, ?, album_id, path, filename, title, artist,
                            album, composer, genre, year, duration, format, file_size, date_added, date_modified,
                            track_artwork_data, is_favorite, play_count, last_played_date, is_duplicate,
                            primary_track_id, duplicate_group_id, album_artist, track_number, total_tracks,
                            disc_number, total_discs, rating, compilation, release_date, original_release_date,
                            bpm, media_type, bitrate, sample_rate, channels, codec, bit_depth, lossless,
                            sort_title, sort_artist, sort_album, sort_album_artist, extended_metadata
                        FROM tracks
                    """,
                    arguments: [RemoteTrackEnrichmentState.completed.rawValue]
                )
            }
        } else {
            try db.execute(
                sql: """
                    INSERT INTO tracks_rebuild (
                        id, folder_id, source_id, source_kind, remote_item_id, remote_enrichment_state, album_id, path, filename, title, artist,
                        album, composer, genre, year, duration, format, file_size, date_added, date_modified,
                        track_artwork_data, is_favorite, play_count, last_played_date, is_duplicate,
                        primary_track_id, duplicate_group_id, album_artist, track_number, total_tracks,
                        disc_number, total_discs, rating, compilation, release_date, original_release_date,
                        bpm, media_type, bitrate, sample_rate, channels, codec, bit_depth, lossless,
                        sort_title, sort_artist, sort_album, sort_album_artist, extended_metadata
                    )
                    SELECT
                        id, folder_id, NULL, ?, NULL, ?, album_id, path, filename, title, artist,
                        album, composer, genre, year, duration, format, file_size, date_added, date_modified,
                        track_artwork_data, is_favorite, play_count, last_played_date, is_duplicate,
                        primary_track_id, duplicate_group_id, album_artist, track_number, total_tracks,
                        disc_number, total_discs, rating, compilation, release_date, original_release_date,
                        bpm, media_type, bitrate, sample_rate, channels, codec, bit_depth, lossless,
                        sort_title, sort_artist, sort_album, sort_album_artist, extended_metadata
                    FROM tracks
                """,
                arguments: [LibrarySourceKind.local.rawValue, RemoteTrackEnrichmentState.completed.rawValue]
            )
        }

        try db.execute(sql: "DROP TABLE tracks")
        try db.execute(sql: "ALTER TABLE tracks_rebuild RENAME TO tracks")

        try DatabaseManager.createIndices(in: db)
        try DatabaseManager.createFTSTable(in: db)
    }
}

// MARK: - Migration Helpers

extension Database {
    /// Helper to safely add a column if it doesn't exist
    func addColumnIfNotExists(
        table: String,
        column: String,
        type: Database.ColumnType,
        defaultValue: DatabaseValueConvertible? = nil,
        notNull: Bool = false
    ) throws {
        let columns = try self.columns(in: table)
        let columnExists = columns.contains { $0.name == column }
        
        if !columnExists {
            try self.alter(table: table) { t in
                var columnDef = t.add(column: column, type)
                if let defaultValue = defaultValue {
                    columnDef = columnDef.defaults(to: defaultValue)
                }
                if notNull {
                    columnDef = columnDef.notNull()
                }
            }
        }
    }
    
    /// Helper to drop a column if it exists
    func dropColumnIfExists(table: String, column: String) throws {
        let columns = try self.columns(in: table)
        let columnExists = columns.contains { $0.name == column }
        
        if columnExists {
            try self.alter(table: table) { t in
                t.drop(column: column)
            }
        }
    }
    
    /// Helper to create an index if it doesn't exist
    func createIndexIfNotExists(
        name: String,
        table: String,
        columns: [String],
        unique: Bool = false
    ) throws {
        let indexExists = try self.indexes(on: table).contains { $0.name == name }
        
        if !indexExists {
            try self.create(
                index: name,
                on: table,
                columns: columns,
                unique: unique,
                ifNotExists: true
            )
        }
    }
    
    /// Helper to drop an index if it exists
    func dropIndexIfExists(_ name: String) throws {
        // Note: We need to find which table the index belongs to
        // For now, we'll try to drop it and ignore errors if it doesn't exist
        do {
            try self.drop(index: name)
        } catch {
            // Index might not exist, which is fine
        }
    }
    
    /// Helper to rename a table if it exists
    func renameTableIfExists(from oldName: String, to newName: String) throws {
        if try self.tableExists(oldName) && !self.tableExists(newName) {
            try self.rename(table: oldName, to: newName)
        }
    }
    
    /// Helper to create a table only if it doesn't exist
    func createTableIfNotExists(
        _ name: String,
        body: (TableDefinition) throws -> Void
    ) throws {
        try self.create(table: name, ifNotExists: true, body: body)
    }
    
    /// Helper to drop a table if it exists
    func dropTableIfExists(_ name: String) throws {
        if try self.tableExists(name) {
            try self.drop(table: name)
        }
    }
    
    /// Helper to rename a column if it exists
    func renameColumnIfExists(
        table: String,
        from oldName: String,
        to newName: String
    ) throws {
        let columns = try self.columns(in: table)
        let oldExists = columns.contains { $0.name == oldName }
        let newExists = columns.contains { $0.name == newName }
        
        if oldExists && !newExists {
            try self.alter(table: table) { t in
                t.rename(column: oldName, to: newName)
            }
        }
    }
}
