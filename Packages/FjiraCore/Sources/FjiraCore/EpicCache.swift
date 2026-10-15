import CryptoKit
import Foundation
import GRDB

public struct CachedJiraEpic: Codable, Sendable {
    public let epic: JiraEpicLink
    public let response: Data
    public let fetchedAt: Date
}

extension JiraClient {
    public func epic(site: JiraSite, token: String, key: String) async throws -> CachedJiraEpic {
        guard JiraEpicLink.validKey(key) else { throw JiraError.invalidResponse }
        return try await epicRequests.value(client: self, site: site, token: token, key: key)
    }
}

actor JiraEpicRequests {
    private var saved: [String: CachedJiraEpic] = [:]
    private var pending: [String: Task<CachedJiraEpic, any Error>] = [:]

    func value(client: JiraClient, site: JiraSite, token: String, key: String) async throws -> CachedJiraEpic {
        let credential = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let identity = site.identifier + ":" + credential + ":" + key
        saved = saved.filter { Date().timeIntervalSince($0.value.fetchedAt) < 300 }
        if let value = saved[identity] { return value }
        if let task = pending[identity] { return try await task.value }
        let task = Task {
            let response = try await client.fetch("epic/\(key)", site: site, token: token, agile: true)
            let epic: JiraEpicLink = try client.decode(response)
            guard epic.key == key, epic.name != nil else { throw JiraError.invalidResponse }
            return CachedJiraEpic(epic: epic, response: response, fetchedAt: Date())
        }
        pending[identity] = task
        defer { pending[identity] = nil }
        let result = try await task.value
        saved[identity] = result
        return result
    }
}

extension ConnectionCache {
    public func saveEpic(_ epic: CachedJiraEpic, site: String, account: String) throws {
        try database.write { db in try Self.writeEpic(epic, in: db, site: site, account: account) }
    }

    public func loadEpic(site: String, account: String, key: String) throws -> CachedJiraEpic? {
        try database.read { db in try Self.epics([key], in: db, site: site, account: account)[key] }
    }

    static func writeEpic(_ epic: CachedJiraEpic, in db: Database, site: String, account: String) throws {
        try db.execute(sql: """
            INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
            """, arguments: [site, account, "epic:\(epic.epic.key)", try JSONEncoder().encode(epic)])
    }

    static func epics(_ keys: [String], in db: Database, site: String, account: String) throws -> [String: CachedJiraEpic] {
        let keys = Array(Set(keys))
        var result: [String: CachedJiraEpic] = [:]
        for offset in stride(from: 0, to: keys.count, by: 200) {
            let resources = keys[offset..<min(offset + 200, keys.count)].map { "epic:\($0)" }
            let placeholders = Array(repeating: "?", count: resources.count).joined(separator: ",")
            let payloads = try Data.fetchAll(db, sql: """
                SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource IN (\(placeholders))
                """, arguments: StatementArguments([site, account] + resources))
            for payload in payloads {
                let saved = try JSONDecoder().decode(CachedJiraEpic.self, from: payload)
                result[saved.epic.key] = saved
            }
        }
        return result
    }
}
