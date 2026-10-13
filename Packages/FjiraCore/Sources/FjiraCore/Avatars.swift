import Foundation
import ImageIO
import GRDB

public struct CachedAvatar: Codable, Sendable {
    public let data: Data
    public let mimeType: String
    public let fetchedAt: Date
    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

extension JiraClient {
    public func avatar(site: JiraSite, token: String, url: URL) async throws -> CachedAvatar {
        var current = url
        for _ in 0..<4 {
            guard let components = URLComponents(url: current, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https", components.host != nil,
                  components.user == nil, components.password == nil else { throw JiraError.invalidURL }
            var request = URLRequest(url: current)
            request.setValue("image/png,image/jpeg,image/gif,image/webp,image/svg+xml", forHTTPHeaderField: "Accept")
            if sameOrigin(current, site.url) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let destination = URL(string: location, relativeTo: current)?.absoluteURL {
                current = destination
                continue
            }
            guard response.statusCode == 200 else { throw JiraError.httpStatus(response.statusCode) }
            guard data.count <= 2_000_000, let mime = imageType(data) else { throw JiraError.invalidResponse }
            if mime != "image/svg+xml" {
                guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 else {
                    throw JiraError.invalidResponse
                }
            }
            return CachedAvatar(data: data, mimeType: mime, fetchedAt: Date())
        }
        throw JiraError.redirected
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private func imageType(_ data: Data) -> String? {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if bytes.starts(with: [255, 216, 255]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.prefix(4) == Array("RIFF".utf8)[...], bytes.suffix(4) == Array("WEBP".utf8)[...] { return "image/webp" }
        if SVGImageValidator.isValid(data) { return "image/svg+xml" }
        return nil
    }
}

private final class SVGImageValidator: NSObject, XMLParserDelegate {
    private var sawRoot = false
    private var depth = 0
    private var styleDepth: Int?
    private var styleText = ""
    private var valid = true

    static func isValid(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              !text.lowercased().contains("<!doctype") else { return false }
        let validator = SVGImageValidator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        return parser.parse() && validator.valid && validator.sawRoot
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let element = elementName.split(separator: ":").last?.lowercased() ?? ""
        if depth == 0 {
            sawRoot = element == "svg"
            if !sawRoot { reject(parser); return }
        }
        depth += 1
        // Icons must be self-contained static images, without scripts or remote assets.
        if ["script", "foreignobject", "iframe", "object", "embed", "link", "meta", "animate", "animatetransform", "animatemotion", "set"].contains(element) {
            reject(parser); return
        }
        for (name, value) in attributeDict {
            let attribute = name.lowercased()
            if attribute.hasPrefix("on") || attribute == "xml:base" || !Self.localReferencesOnly(value) {
                reject(parser); return
            }
            if attribute.split(separator: ":").last == "href", !value.hasPrefix("#") {
                reject(parser); return
            }
        }
        if element == "style" { styleDepth = depth; styleText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth != nil { styleText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if styleDepth != nil { styleText += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if styleDepth == depth {
            if !Self.localReferencesOnly(styleText) { reject(parser) }
            styleDepth = nil
        }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        reject(parser)
    }

    private func reject(_ parser: XMLParser) {
        valid = false
        parser.abortParsing()
    }

    private static func localReferencesOnly(_ value: String) -> Bool {
        guard !value.lowercased().contains("@import"), !value.contains("\\"),
              let expression = try? NSRegularExpression(pattern: #"url\s*\((.*?)\)"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return false }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).allSatisfy { match in
            guard let range = Range(match.range(at: 1), in: value) else { return false }
            let reference = value[range].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return reference.hasPrefix("#")
        }
    }
}

extension ConnectionCache {
    public func saveAvatar(_ avatar: CachedAvatar, site: String, account: String, url: URL) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
                """, arguments: [site, account, "avatar:\(url.absoluteString)", try JSONEncoder().encode(avatar)])
        }
    }

    public func loadAvatar(site: String, account: String, url: URL) throws -> CachedAvatar? {
        try database.read { db in
            guard let data = try Data.fetchOne(db,
                sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
                arguments: [site, account, "avatar:\(url.absoluteString)"]) else { return nil }
            return try JSONDecoder().decode(CachedAvatar.self, from: data)
        }
    }
}
