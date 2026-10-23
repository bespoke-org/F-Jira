import Foundation
import XCTest
@testable import FjiraCore

final class JiraRateLimitTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com/jira")

    func testRetryAfterSupportsSecondsAndHTTPDatesAndRejectsInvalidValues() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(String?, TimeInterval?)] = [
            ("12", 12), (" 0 ", 0), ("0.5", 0.5),
            ("Tue, 14 Nov 2023 22:13:25 GMT", 5),
            ("Tue, 14 Nov 2023 22:13:15 GMT", 0),
            (nil, nil), ("invalid", nil), ("-1", nil), ("nan", nil), ("inf", nil)
        ]
        for (header, expected) in cases {
            let response = try XCTUnwrap(HTTPURLResponse(url: site.url, statusCode: 429, httpVersion: nil,
                headerFields: header.map { ["Retry-After": $0] }))
            XCTAssertEqual(JiraRateLimitedTransport.retryAfter(response, now: now), expected, header ?? "missing")
        }
    }

    func test429RetriesTheSameSearchRequestAfterServerDelay() async throws {
        let transport = RateLimitTransport(statuses: [429, 200], retryAfter: "2")
        let client = JiraClient(transport: transport)
        let body = Data(#"{"jql":"project = EX"}"#.utf8)
        let result = try await client.fetch("search", site: site, token: "token", body: body)
        XCTAssertEqual(result, Data("ok".utf8))
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertGreaterThanOrEqual(calls[1].time - calls[0].time, 2)
        XCTAssertEqual(calls[0].request, calls[1].request)
        XCTAssertEqual(calls[1].request.httpMethod, "POST")
        XCTAssertEqual(calls[1].request.httpBody, body)
    }

    func testMissingHeaderUsesBackoffAndRepeated429StopsAfterThreeRetries() async throws {
        let transport = RateLimitTransport(statuses: [429, 429, 429, 429], retryAfter: nil)
        let client = JiraClient(transport: transport)
        do {
            _ = try await client.fetch("board/1/issue", site: site, token: "token", agile: true)
            XCTFail("Expected the final rate limit error")
        } catch { XCTAssertEqual(error as? JiraError, .httpStatus(429)) }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 4)
        for index in 1..<calls.count {
            XCTAssertGreaterThanOrEqual(calls[index].time - calls[index - 1].time, pow(2, Double(index - 1)))
        }
    }

    func testCooldownSurvivesCancellationAndIsSharedOnlyForSameServerAndCredential() async throws {
        let transport = RateLimitTransport(statuses: [429, 200, 200, 200], retryAfter: "2")
        let client = JiraClient(transport: transport)
        let original = Task { [site] in try await client.fetch("board/1/issue", site: site, token: "token", agile: true) }
        defer { original.cancel() }
        try await waitForFirstRequest(transport)
        original.cancel()
        do {
            _ = try await original.value
            XCTFail("Cancellation must interrupt the retry wait")
        } catch { XCTAssertTrue(error is CancellationError) }
        let afterCancellation = await transport.calls
        XCTAssertEqual(afterCancellation.count, 1)

        // Neither another server nor another credential should inherit the cooldown.
        _ = try await client.fetch("myself", site: JiraSite("https://other.example.com"), token: "token")
        _ = try await client.fetch("myself", site: site, token: "another-token")
        let copy = client
        _ = try await copy.fetch("board/2/configuration", site: site, token: "token", agile: true)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertLessThan(calls[1].time - calls[0].time, 1)
        XCTAssertLessThan(calls[2].time - calls[0].time, 1)
        XCTAssertGreaterThanOrEqual(calls[3].time - calls[0].time, 2)
    }

    func testLongRetryWaitCanBeCancelledPromptly() async throws {
        let transport = RateLimitTransport(statuses: [429], retryAfter: "120")
        let client = JiraClient(transport: transport)
        let request = Task { [site] in try await client.fetch("myself", site: site, token: "token") }
        defer { request.cancel() }
        try await waitForFirstRequest(transport)
        let start = ProcessInfo.processInfo.systemUptime
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancelled request should not retry")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testOtherErrorsAreNotRetried() async throws {
        let transport = RateLimitTransport(statuses: [403], retryAfter: "1")
        let client = JiraClient(transport: transport)
        do {
            _ = try await client.fetch("myself", site: site, token: "token")
            XCTFail("Expected forbidden")
        } catch { XCTAssertEqual(error as? JiraError, .forbidden) }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    private func waitForFirstRequest(_ transport: RateLimitTransport) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await transport.calls.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let calls = await transport.calls
        XCTAssertFalse(calls.isEmpty)
    }
}

private actor RateLimitTransport: JiraTransport {
    struct Call: Sendable {
        let request: URLRequest
        let time: TimeInterval
    }
    private(set) var calls: [Call] = []
    let statuses: [Int]
    let retryAfter: String?

    init(statuses: [Int], retryAfter: String?) {
        self.statuses = statuses
        self.retryAfter = retryAfter
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = calls.count
        calls.append(Call(request: request, time: ProcessInfo.processInfo.systemUptime))
        guard statuses.indices.contains(index) else { throw JiraError.invalidResponse }
        return (Data("ok".utf8), HTTPURLResponse(url: request.url!, statusCode: statuses[index], httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] })!)
    }
}
