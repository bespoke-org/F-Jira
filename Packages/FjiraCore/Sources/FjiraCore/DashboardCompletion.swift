import Foundation

public struct CompletionWeek: Codable, Identifiable, Sendable {
    public let start: Date
    public let end: Date
    public let query: ProjectQuery
    public var id: Date { start }

    static func periods(now: Date, timeZone: TimeZone, projectID: String,
                        configuration: DashboardConfiguration, count: Int = 10) throws -> [CompletionWeek] {
        guard count > 0 else { throw JiraError.invalidResponse }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        guard let current = calendar.dateInterval(of: .weekOfYear, for: now) else { throw JiraError.invalidResponse }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return try (-(count - 1)...0).map { offset in
            guard let start = calendar.date(byAdding: .weekOfYear, value: offset, to: current.start),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { throw JiraError.invalidResponse }
            let filter = "\(configuration.ownershipJQL) AND statusCategory = Done AND resolved >= \"\(formatter.string(from: start))\" AND resolved < \"\(formatter.string(from: end))\" ORDER BY resolved DESC"
            return CompletionWeek(start: start, end: end, query: try ProjectQuery(projectID: projectID, input: "jql: " + filter))
        }
    }
}

public struct CompletedWeek: Codable, Identifiable, Sendable {
    public let period: CompletionWeek
    public let count: Int
    public let response: Data
    public var id: Date { period.start }
}

public struct CachedDashboardCompletion: Codable, Sendable {
    public let weeks: [CompletedWeek]
    public let timeZoneIdentifier: String
    public let profileResponse: Data
    public let fetchedAt: Date
    public var currentWeek: CompletedWeek? { weeks.last }
    public var previousWeeks: [CompletedWeek] { Array(weeks.dropLast()) }
    public var lastWeek: CompletedWeek? { previousWeeks.last }

    public func label(for week: CompletedWeek) -> String {
        var format = Date.FormatStyle().month(.abbreviated).day()
        format.timeZone = timeZone
        return week.period.start.formatted(format)
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .gmt }

    public func isCurrentWeek(at date: Date = Date()) -> Bool {
        guard let currentWeek else { return false }
        return currentWeek.period.start <= date && date < currentWeek.period.end
    }
}

extension JiraClient {
    public func dashboardCompletion(site: JiraSite, token: String, projectID: String,
                                    configuration: DashboardConfiguration, now: Date = Date(), weekCount: Int = 10,
                                    reusing cached: CachedDashboardCompletion? = nil) async throws -> CachedDashboardCompletion {
        struct Profile: Decodable { let timeZone: String }
        let reusable = cached.flatMap { $0.isCurrentWeek(at: now) ? $0 : nil }
        let profileResponse: Data
        if let reusable { profileResponse = reusable.profileResponse }
        else { profileResponse = try await fetch("myself", site: site, token: token) }
        let profile: Profile = try decode(profileResponse)
        guard let timeZone = TimeZone(identifier: profile.timeZone) else { throw JiraError.invalidResponse }
        let periods = try CompletionWeek.periods(now: now, timeZone: timeZone, projectID: projectID,
                                                configuration: configuration, count: weekCount)
        let known = Dictionary((reusable?.weeks ?? []).map { ($0.period.query, $0) }, uniquingKeysWith: { first, _ in first })
        let retained = periods.compactMap { known[$0.query] }
        let missing = periods.filter { known[$0.query] == nil }
        let weeks = try await withThrowingTaskGroup(of: CompletedWeek.self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<3 {
                if let period = iterator.next() {
                    group.addTask { try await self.completedWeek(period, site: site, token: token) }
                }
            }
            var results: [CompletedWeek] = retained
            while let result = try await group.next() {
                results.append(result)
                if let period = iterator.next() {
                    group.addTask { try await self.completedWeek(period, site: site, token: token) }
                }
            }
            return results.sorted { $0.period.start < $1.period.start }
        }
        return CachedDashboardCompletion(weeks: weeks, timeZoneIdentifier: profile.timeZone,
                                         profileResponse: profileResponse, fetchedAt: reusable?.fetchedAt ?? Date())
    }

    private func completedWeek(_ period: CompletionWeek, site: JiraSite, token: String) async throws -> CompletedWeek {
        struct Request: Encodable {
            let jql: String
            let startAt = 0
            let maxResults = 0
            let fields: [String] = []
        }
        struct Count: Decodable { let total: Int }
        let response = try await fetch("search", site: site, token: token,
                                       body: JSONEncoder().encode(Request(jql: period.query.jql)))
        let result: Count = try decode(response)
        guard result.total >= 0 else { throw JiraError.invalidResponse }
        return CompletedWeek(period: period, count: result.total, response: response)
    }
}
