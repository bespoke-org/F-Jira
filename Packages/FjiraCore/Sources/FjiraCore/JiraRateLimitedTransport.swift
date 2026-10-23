import CryptoKit
import Foundation

/// Shared by copies of a client, so one 429 pauses new requests and retries for that server/account.
actor JiraRateLimitedTransport: JiraTransport {
    private struct Scope: Hashable {
        let scheme: String?
        let host: String?
        let port: Int?
        let credential: String

        init(_ request: URLRequest) {
            scheme = request.url?.scheme?.lowercased()
            host = request.url?.host?.lowercased()
            port = request.url?.port ?? (scheme == "https" ? 443 : 80)
            credential = SHA256.hash(data: Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    private let transport: any JiraTransport
    // Monotonic deadlines keep a system clock adjustment from shortening a server's cooldown.
    private var deadlines: [Scope: TimeInterval] = [:]

    init(transport: any JiraTransport) { self.transport = transport }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let scope = Scope(request)
        var retries = 0
        while true {
            try await wait(for: scope)
            try Task.checkCancellation()
            let result = try await transport.data(for: request)
            guard result.1.statusCode == 429 else { return result }

            let backoff = pow(2, Double(retries))
            let delay = max(Self.retryAfter(result.1) ?? 0, backoff) + Double.random(in: 0...(backoff * 0.25))
            let now = ProcessInfo.processInfo.systemUptime
            deadlines = deadlines.filter { $0.value > now }
            deadlines[scope] = max(deadlines[scope] ?? now, now + delay)
            // Preserve the final 429 for the caller's normal error handling, and its cooldown for other calls.
            guard retries < 3 else { return result }
            retries += 1
        }
    }

    private func wait(for scope: Scope) async throws {
        while let deadline = deadlines[scope] {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                deadlines[scope] = nil
                return
            }
            // Recheck the shared deadline after waking; another 429 may have extended it.
            try await Task.sleep(for: .seconds(min(remaining, 60)))
        }
    }

    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
