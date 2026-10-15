import Foundation

public struct JiraSite: Codable, Hashable, Sendable {
    public let url: URL

    public init(_ input: String) throws {
        guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw JiraError.invalidURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw JiraError.invalidURL }
        self.url = url
    }

    public var identifier: String { url.absoluteString }

    public func endpoint(_ resource: String) -> URL {
        url.appending(path: "rest/api/2/\(resource)")
    }
}

public struct JiraUser: Codable, Sendable {
    public let name: String
    public let displayName: String
    public let key: String?
    public let active: Bool?
    public let avatarUrls: [String: URL]?
    public var identifier: String { key ?? name }
    public var avatarURL: URL? {
        ["48x48", "32x32", "24x24", "16x16"].compactMap { avatarUrls?[$0] }.first
            ?? avatarUrls?.sorted { $0.key < $1.key }.first?.value
    }
}

public struct JiraServer: Codable, Sendable {
    public let version: String
    public let serverTitle: String?
}

public struct CachedConnection: Codable, Sendable {
    public let site: JiraSite
    public let user: JiraUser
    public let server: JiraServer
    public let fetchedAt: Date
    public let userResponse: Data
    public let serverResponse: Data

    public var profileUser: JiraUser {
        // Older snapshots omitted avatar URLs in the typed user but retained the full response.
        guard user.avatarURL == nil,
              let decoded = try? JSONDecoder().decode(JiraUser.self, from: userResponse),
              decoded.identifier == user.identifier else { return user }
        return decoded
    }
}

public enum JiraError: LocalizedError, Equatable {
    case invalidURL, missingToken, unauthorized, forbidden, notFound, redirected, invalidResponse
    case httpStatus(Int)
    case queryRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS Jira base URL, including its context path if needed. Leave out credentials, query parameters, and fragments."
        case .missingToken: "Enter a personal access token."
        case .unauthorized: "Jira rejected the token. Check that it is valid and has not expired."
        case .forbidden: "Your account cannot access this Jira API. Check your permissions or whether personal access tokens are enabled."
        case .notFound: "The Jira API was not found. Check the base URL and any context path, such as /jira."
        case .redirected: "Jira redirected the API request. Use its final HTTPS base URL; a browser sign-in page cannot verify a personal access token."
        case .invalidResponse: "The server did not return the expected Jira data. Check the base URL and whether a sign-in proxy is intercepting API requests."
        case .queryRejected(let message): "Jira rejected the query: \(message)"
        case .httpStatus(let status): "Jira returned HTTP \(status). Try again later."
        }
    }
}

public protocol JiraTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct URLSessionTransport: JiraTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        return (data, response)
    }
}

public struct JiraClient: Sendable {
    let transport: any JiraTransport

    public init(transport: any JiraTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func verify(site: JiraSite, token: String) async throws -> CachedConnection {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
            throw JiraError.missingToken
        }
        let userData = try await fetch("myself", site: site, token: token)
        let user: JiraUser = try decode(userData)
        let serverData = try await fetch("serverInfo", site: site, token: token)
        let server: JiraServer = try decode(serverData)
        return CachedConnection(
            site: site, user: user, server: server, fetchedAt: Date(),
            userResponse: userData, serverResponse: serverData
        )
    }

    func fetch(_ resource: String, site: JiraSite, token: String, body: Data? = nil, queryItems: [URLQueryItem] = [], agile: Bool = false, greenhopper: Bool = false) async throws -> Data {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw JiraError.missingToken }
        let endpoint = greenhopper ? site.url.appending(path: "rest/greenhopper/1.0/\(resource)")
            : (agile ? site.url.appending(path: "rest/agile/1.0/\(resource)") : site.endpoint(resource))
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw JiraError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw JiraError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300: return data
        case 300..<400: throw JiraError.redirected
        case 400:
            struct ErrorResponse: Decodable {
                let errorMessages: [String]?
                let errors: [String: String]?
            }
            let details = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let messages = (details?.errorMessages ?? []) + (details?.errors?.sorted { $0.key < $1.key }.map(\.value) ?? [])
            throw JiraError.queryRejected(messages.isEmpty ? "Check your JQL syntax and field names." : messages.joined(separator: "\n"))
        case 401: throw JiraError.unauthorized
        case 403: throw JiraError.forbidden
        case 404: throw JiraError.notFound
        default: throw JiraError.httpStatus(response.statusCode)
        }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw JiraError.invalidResponse }
    }
}
