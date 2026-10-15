import Foundation

public struct JiraEpicLink: Codable, Sendable {
    public let key: String
    public let id: String?
    public let summary: String?
    public var name: String? = nil
    public var color: Color? = nil

    public struct Color: Codable, Sendable {
        public let key: String
    }

    public var displayName: String {
        [name, summary].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? key
    }

    public var pillTitle: String {
        let title = displayName
        return title.count > 35 ? String(title.prefix(34)) + "…" : title
    }

    public var hasPresentation: Bool { name != nil && color != nil }

    func restoringPresentation(from other: JiraEpicLink?) -> JiraEpicLink {
        guard let other, other.key == key else { return self }
        return JiraEpicLink(key: key, id: id ?? other.id, summary: summary ?? other.summary,
                            name: name ?? other.name, color: color ?? other.color)
    }

    public var listIssue: JiraIssue {
        JiraIssue(id: id ?? key, key: key, fields: .init(summary: summary, status: nil, assignee: nil,
                                                      priority: nil, updated: nil, issuetype: nil))
    }

    static func decode(from decoder: any Decoder) -> JiraEpicLink? {
        guard let root = try? decoder.container(keyedBy: FieldKey.self),
              let fields = try? root.nestedContainer(keyedBy: FieldKey.self, forKey: FieldKey("fields")) else { return nil }
        if let agile = try? fields.decode(JiraEpicLink.self, forKey: FieldKey("epic")), validKey(agile.key) { return agile }
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

    static func validKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Z][A-Z0-9_]*-[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension JiraEpicLink {
    private enum CodingKeys: String, CodingKey { case key, id, summary, name, color }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        guard Self.validKey(key) else { throw JiraError.invalidResponse }
        id = (try? values.decode(String.self, forKey: .id))
            ?? (try? values.decode(Int.self, forKey: .id)).map(String.init)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        color = (try? values.decode(Color.self, forKey: .color))
            ?? (try? values.decode(String.self, forKey: .color)).map { Color(key: $0) }
    }
}

/// Server/Data Center epic colors, shared by the web body and native board cards.
public struct JiraEpicPalette: Sendable {
    private let base: UInt32

    public init(colorKey: String?) {
        let colors: [UInt32] = [0x8D542E, 0xFF8B00, 0xFFAB00, 0x0052CC, 0x505F79, 0x60A222, 0xCC4388,
                                0x5243AA, 0xFF8F73, 0x2684FF, 0x008DA6, 0x6B778C, 0x00875A, 0xDE350B]
        let index = colorKey.flatMap { key in
            ["color_", "ghx-label-"].first(where: key.hasPrefix).flatMap { Int(key.dropFirst($0.count)) }
        }
        base = index.flatMap { (1...colors.count).contains($0) ? colors[$0 - 1] : nil } ?? 0x6B778C
    }

    public func palette(dark: Bool) -> JiraStatusPalette {
        // Keep the epic hue while softening the fill and adjusting text for each appearance.
        JiraStatusPalette(foreground: blend(toward: dark ? 0xFFFFFF : 0x000000, amount: dark ? 0.5 : 0.38),
                          background: blend(toward: dark ? 0x202124 : 0xFFFFFF, amount: dark ? 0.82 : 0.88))
    }

    private func blend(toward other: UInt32, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let start = Double((base >> shift) & 0xFF)
            let end = Double((other >> shift) & 0xFF)
            return result | (UInt32((start + (end - start) * amount).rounded()) << shift)
        }
    }
}

struct FieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
