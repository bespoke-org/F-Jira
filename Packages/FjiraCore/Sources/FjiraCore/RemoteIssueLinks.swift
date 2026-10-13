import Foundation
import GRDB

public struct RemoteIssueLink: Codable, Identifiable, Sendable {
    public let id: Int
    public let relationship: String?
    public let application: Application?
    public let object: RemoteObject

    public struct Application: Codable, Sendable {
        public let name: String?
        public let type: String?
    }

    public struct RemoteObject: Codable, Sendable {
        public let url: URL
        public let title: String
        public let summary: String?
        public let status: Status?
    }

    public struct Status: Codable, Sendable {
        public let resolved: Bool?
    }
}

public struct CachedRemoteIssueLinks: Codable, Sendable {
    public let links: [RemoteIssueLink]
    public let response: Data
    public let fetchedAt: Date
}

extension JiraClient {
    public func remoteIssueLinks(site: JiraSite, token: String, id: String) async throws -> CachedRemoteIssueLinks {
        guard Self.validIssueIdentifier(id) else { throw JiraError.invalidResponse }
        let response = try await fetch("issue/\(id)/remotelink", site: site, token: token)
        let links: [RemoteIssueLink] = try decode(response)
        return CachedRemoteIssueLinks(links: links, response: response, fetchedAt: Date())
    }
}

extension ConnectionCache {
    public func saveRemoteIssueLinks(_ links: CachedRemoteIssueLinks, site: String, account: String,
                                     id: String, expectedGeneration: UUID) throws {
        try database.write { db in
            guard var detail = try Self.readDetail(in: db, site: site, account: account, id: id),
                  detail.generation == expectedGeneration else { throw SearchError.inconsistentPagination }
            detail.remoteLinks = links
            try Self.writeDetail(detail, in: db, site: site, account: account)
        }
    }
}
