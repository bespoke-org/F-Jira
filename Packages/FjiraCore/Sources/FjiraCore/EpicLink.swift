import Foundation

public struct JiraEpicLink: Codable, Sendable {
    public let key: String
    public let id: String?
    public let summary: String?

    public var listIssue: JiraIssue {
        JiraIssue(id: id ?? key, key: key, fields: .init(summary: summary, status: nil, assignee: nil,
                                                      priority: nil, updated: nil, issuetype: nil))
    }

    static func decode(from decoder: any Decoder) -> JiraEpicLink? {
        guard let root = try? decoder.container(keyedBy: FieldKey.self),
              let fields = try? root.nestedContainer(keyedBy: FieldKey.self, forKey: FieldKey("fields")) else { return nil }
        struct Schema: Decodable { let custom: String? }
        let schemas = (try? root.decode([String: Schema].self, forKey: FieldKey("schema"))) ?? [:]
        let names = (try? root.decode([String: String].self, forKey: FieldKey("names"))) ?? [:]
        let typed = schemas.keys.filter { schemas[$0]?.custom == "com.pyxis.greenhopper.jira:gh-epic-link" }.sorted()
        let named = names.keys.filter { names[$0]?.split(whereSeparator: \.isWhitespace).joined().lowercased() == "epiclink" }.sorted()
        for field in typed.isEmpty ? named : typed {
            let valueKey = FieldKey(field)
            if let key = try? fields.decode(String.self, forKey: valueKey), validKey(key) {
                return JiraEpicLink(key: key, id: nil, summary: nil)
            }
            struct Reference: Decodable {
                let key: String
                let id: String?
                let fields: Summary?
                struct Summary: Decodable { let summary: String? }
            }
            if let reference = try? fields.decode(Reference.self, forKey: valueKey), validKey(reference.key) {
                let id = reference.id.flatMap { JiraClient.validIssueIdentifier($0) ? $0 : nil }
                return JiraEpicLink(key: reference.key, id: id, summary: reference.fields?.summary)
            }
        }
        return nil
    }

    private static func validKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Z][A-Z0-9_]*-[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct FieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
