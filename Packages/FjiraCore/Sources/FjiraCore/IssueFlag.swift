import CryptoKit
import Foundation

/// nil means the response did not include flag information, not that the flag was cleared.
enum JiraFlag {
    static func fieldIDs(names: [String: String]) -> [String] {
        names.keys.filter { names[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "flagged" }.sorted()
    }

    static func decode(from decoder: any Decoder, names: [String: String] = [:]) -> Bool? {
        guard let root = try? decoder.container(keyedBy: FieldKey.self) else { return nil }
        if let saved = try? root.decode(Bool.self, forKey: FieldKey("flagged")) { return saved }
        guard let fields = try? root.nestedContainer(keyedBy: FieldKey.self, forKey: FieldKey("fields")) else { return nil }
        if let agile = try? fields.decode(Bool.self, forKey: FieldKey("flagged")) { return agile }
        let names = (try? root.decode([String: String].self, forKey: FieldKey("names"))) ?? names
        struct Option: Decodable { let id: String?; let value: String? }
        var known = false
        for id in fieldIDs(names: names) {
            let key = FieldKey(id)
            guard fields.contains(key) else { continue }
            if (try? fields.decodeNil(forKey: key)) == true { known = true; continue }
            if let options = try? fields.decode([Option].self, forKey: key) {
                if !options.isEmpty { return true }
                known = true
            }
        }
        return known ? false : nil
    }
}

/// Shares field discovery across pages without an extra request for each issue.
actor JiraFlagFields {
    private struct Entry {
        let expires: Date
        let task: Task<[String], Never>
    }
    private var entries: [String: Entry] = [:]

    func ids(client: JiraClient, site: JiraSite, token: String) async -> [String] {
        let credential = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = site.identifier + ":" + credential
        if let entry = entries[key], entry.expires > Date() { return await entry.task.value }
        let task = Task<[String], Never> {
            struct Field: Decodable { let id: String; let name: String }
            guard let data = try? await client.fetch("field", site: site, token: token),
                  let fields = try? JSONDecoder().decode([Field].self, from: data) else { return [] }
            return JiraFlag.fieldIDs(names: Dictionary(fields.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        }
        entries = entries.filter { $0.value.expires > Date() }
        entries[key] = Entry(expires: Date().addingTimeInterval(300), task: task)
        return await task.value
    }
}

