import Foundation
import GRDB

extension ConnectionCache {
    public func loadBoardImages(site: String, account: String, urls: [URL]) throws -> [String: CachedAvatar] {
        try database.read { db in try Self.cachedImages(in: db, site: site, account: account, urls: urls) }
    }

    public func saveBoards(_ boards: CachedBoards, site: String, account: String, project: String) throws {
        try saveBoardValue(boards, site: site, account: account, resource: "boards:\(project)")
    }

    public func loadBoards(site: String, account: String, project: String) throws -> CachedBoards? {
        try loadBoardValue(site: site, account: account, resource: "boards:\(project)")
    }

    public func saveBoard(_ board: CachedBoard, site: String, account: String) throws {
        _ = try reconcileIssues(board.issues, site: site, account: account)
        try saveBoardValue(board, site: site, account: account, resource: "board:\(board.board.id)")
    }

    /// Keep each received page even when an interrupted refresh retains the last complete board.
    public func saveBoardResponse(_ data: Data, site: String, account: String, boardID: Int, resource: String) throws {
        try saveBoardValue(data, site: site, account: account, resource: "board-response:\(boardID):\(resource)")
    }

    public func loadBoardPresentation(site: String, account: String, boardID: Int) throws
        -> (board: CachedBoard, images: [String: CachedAvatar])? {
        try database.read { db in
            guard let data = try Data.fetchOne(db,
                sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
                arguments: [site, account, "board:\(boardID)"]) else { return nil }
            let saved = try JSONDecoder().decode(CachedBoard.self, from: data)
            let known = try Self.knownIssues(saved.issues.map(\.id), in: db, site: site, account: account)
            let board = saved.reconciling(known.values.map(\.issue))
            return (board, try Self.cachedImages(in: db, site: site, account: account, urls: board.imageURLs))
        }
    }

    public func saveBoardSelection(_ boardID: Int, site: String, account: String, project: String) throws {
        try saveBoardValue(boardID, site: site, account: account, resource: "board-selection:\(project)")
    }

    public func loadBoardSelection(site: String, account: String, project: String) throws -> Int? {
        try loadBoardValue(site: site, account: account, resource: "board-selection:\(project)")
    }

    private func saveBoardValue<T: Encodable>(_ value: T, site: String, account: String, resource: String) throws {
        let data = try JSONEncoder().encode(value)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
                """, arguments: [site, account, resource, data])
        }
    }

    private func loadBoardValue<T: Decodable>(site: String, account: String, resource: String) throws -> T? {
        try database.read { db in
            guard let data = try Data.fetchOne(db,
                sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
                arguments: [site, account, resource]) else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }
}
