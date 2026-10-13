import Foundation
import GRDB

public actor ConnectionCache {
    let database: DatabaseQueue

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("connections") { db in
            try db.create(table: "connection") { table in
                table.column("site", .text).notNull()
                table.column("account", .text).notNull()
                table.column("snapshot", .blob).notNull()
                table.primaryKey(["site", "account"])
            }
        }
        migrator.registerMigration("projectBrowsing") { db in
            try db.create(table: "project_snapshot") { table in
                table.column("site", .text).notNull()
                table.column("account", .text).notNull()
                table.column("snapshot", .blob).notNull()
                table.primaryKey(["site", "account"])
            }
            try db.create(table: "search_snapshot") { table in
                table.column("site", .text).notNull()
                table.column("account", .text).notNull()
                table.column("project", .text).notNull()
                table.column("input", .text).notNull()
                table.column("snapshot", .blob).notNull()
                table.primaryKey(["site", "account", "project", "input"])
            }
            try db.create(table: "response_cache") { table in
                table.column("site", .text).notNull()
                table.column("account", .text).notNull()
                table.column("resource", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["site", "account", "resource"])
            }
            try db.create(table: "browsing_selection") { table in
                table.column("site", .text).notNull()
                table.column("account", .text).notNull()
                table.column("project", .text).notNull()
                table.column("input", .text).notNull()
                table.primaryKey(["site", "account"])
            }
        }
        try migrator.migrate(database)
    }

    public func save(_ connection: CachedConnection) throws {
        let snapshot = try JSONEncoder().encode(connection)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO connection (site, account, snapshot) VALUES (?, ?, ?)
                    ON CONFLICT(site, account) DO UPDATE SET snapshot = excluded.snapshot
                    """,
                arguments: [connection.site.identifier, connection.user.identifier, snapshot]
            )
        }
    }

    public func load(site: String, account: String) throws -> CachedConnection? {
        try database.read { db in
            guard let data = try Data.fetchOne(
                db, sql: "SELECT snapshot FROM connection WHERE site = ? AND account = ?",
                arguments: [site, account]
            ) else { return nil }
            return try JSONDecoder().decode(CachedConnection.self, from: data)
        }
    }
}
