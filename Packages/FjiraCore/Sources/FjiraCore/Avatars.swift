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
            request.setValue("image/png,image/jpeg,image/gif,image/webp", forHTTPHeaderField: "Accept")
            if sameOrigin(current, site.url) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let destination = URL(string: location, relativeTo: current)?.absoluteURL {
                current = destination
                continue
            }
            guard response.statusCode == 200 else { throw JiraError.httpStatus(response.statusCode) }
            guard data.count <= 2_000_000, let mime = imageType(data),
                  let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 else { throw JiraError.invalidResponse }
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
        return nil
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
