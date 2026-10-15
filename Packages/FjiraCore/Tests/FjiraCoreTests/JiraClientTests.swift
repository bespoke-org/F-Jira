import Foundation
import XCTest
@testable import FjiraCore

actor StubTransport: JiraTransport {
    private var requests: [URLRequest] = []
    private var responseIndex = 0
    let responses: [(Int, Data)]
    let fieldResponse: String

    init(_ responses: [(Int, String)], fieldResponse: String = "[]") {
        self.fieldResponse = fieldResponse
        self.responses = responses.map { ($0.0, Data($0.1.utf8)) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if ["remotelink", "field"].contains(request.url?.lastPathComponent ?? "") {
            return (Data((request.url?.lastPathComponent == "field" ? fieldResponse : "[]").utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let index = responseIndex
        responseIndex += 1
        let (status, data) = responses[index]
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func capturedRequests() -> [URLRequest] { requests }
}

final class JiraClientTests: XCTestCase {
    func testPreservesContextPathAndUsesBearerAuthentication() async throws {
        let transport = StubTransport([
            (200, #"{"name":"alice","key":"JIRAUSER1","displayName":"Alice","active":true,"extra":"retained"}"#),
            (200, #"{"version":"9.12.0","serverTitle":"Team Jira"}"#)
        ])
        let site = try JiraSite(" https://JIRA.example.com:443/jira/ ")
        let result = try await JiraClient(transport: transport).verify(site: site, token: " test-token ")
        XCTAssertEqual(result.site.identifier, "https://jira.example.com/jira")
        XCTAssertEqual(result.user.identifier, "JIRAUSER1")
        XCTAssertEqual(result.server.version, "9.12.0")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/jira/rest/api/2/myself", "/jira/rest/api/2/serverInfo"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        XCTAssertTrue(String(decoding: result.userResponse, as: UTF8.self).contains("retained"))
    }

    func testRejectsInvalidURLs() {
        for url in ["jira.example.com", "http://jira.example.com", "https://", "https://alice:secret@jira.example.com", "https://jira.example.com?token=secret", "https://jira.example.com#fragment"] {
            XCTAssertThrowsError(try JiraSite(url), url)
        }
    }

    func testMissingTokenDoesNotSendRequests() async throws {
        let transport = StubTransport([])
        do {
            _ = try await JiraClient(transport: transport).verify(site: JiraSite("https://jira.example.com"), token: " ")
            XCTFail("Expected a missing token error")
        } catch { XCTAssertEqual(error as? JiraError, .missingToken) }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testStatusErrorsAndHTMLLoginResponse() async throws {
        for (status, body, expected) in [
            (401, "", JiraError.unauthorized), (403, "", .forbidden),
            (404, "", .notFound), (302, "", .redirected),
            (500, "", .httpStatus(500)), (200, "<html>Sign in</html>", .invalidResponse)
        ] {
            let client = JiraClient(transport: StubTransport([(status, body)]))
            do {
                _ = try await client.verify(site: JiraSite("https://jira.example.com"), token: "token")
                XCTFail("Expected an error for \(status)")
            } catch { XCTAssertEqual(error as? JiraError, expected) }
        }
    }

    func testCacheSurvivesReopeningAndIsolatesAccountsAndSites() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let transport = StubTransport([
            (200, #"{"name":"alice","displayName":"Alice"}"#),
            (200, #"{"version":"9.12.0"}"#)
        ])
        let result = try await JiraClient(transport: transport).verify(
            site: JiraSite("https://jira.example.com/jira"), token: "secret-token"
        )
        let first = try ConnectionCache(path: path)
        try await first.save(result)
        let reopened = try ConnectionCache(path: path)
        let restored = try await reopened.load(site: result.site.identifier, account: "alice")
        XCTAssertEqual(restored?.user.displayName, "Alice")
        XCTAssertEqual(restored?.userResponse, result.userResponse)
        XCTAssertEqual(restored?.serverResponse, result.serverResponse)
        XCTAssertEqual(restored?.fetchedAt, result.fetchedAt)
        let otherAccount = try await reopened.load(site: result.site.identifier, account: "bob")
        let otherSite = try await reopened.load(site: "https://other.example.com", account: "alice")
        XCTAssertNil(otherAccount)
        XCTAssertNil(otherSite)
        XCTAssertFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self).contains("secret-token"))
    }
}
