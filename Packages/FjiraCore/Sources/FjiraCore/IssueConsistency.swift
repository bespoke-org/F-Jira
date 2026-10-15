import Foundation

extension JiraIssue {
    /// Jira revisions, not download times, determine which node's response is newer.
    var revision: Date? { fields.updated.flatMap(IssueRevision.date) }
    var statusIdentity: String? { fields.status.map { $0.id ?? $0.name } }

    func prefers(_ candidate: JiraIssue, onEqual: Bool = true) -> Bool {
        guard candidate.id == id else { return false }
        if fields.updated == candidate.fields.updated { return onEqual }
        switch (revision, candidate.revision) {
        case let (old?, new?): return new > old || (new == old && onEqual)
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil): return onEqual
        }
    }

    func accepting(_ candidate: JiraIssue, onEqual: Bool = true) -> JiraIssue {
        guard candidate.id == id else { return self }
        return prefers(candidate, onEqual: onEqual)
            ? candidate.restoringMetadata(from: self) : restoringMetadata(from: candidate)
    }

    func restoringMetadata(from other: JiraIssue) -> JiraIssue {
        var assignee = fields.assignee
        if let user = assignee, let previous = other.fields.assignee,
           user.identifier == previous.identifier || user.name == previous.name {
            assignee = JiraUser(name: user.name, displayName: user.displayName, key: user.key ?? previous.key,
                               active: user.active, avatarUrls: user.avatarUrls ?? previous.avatarUrls)
        }
        return JiraIssue(id: id, key: key, fields: Fields(summary: fields.summary,
            status: fields.status?.restoringMetadata(from: other.fields.status), assignee: assignee,
            priority: fields.priority?.restoringMetadata(from: other.fields.priority), updated: fields.updated,
            issuetype: fields.issuetype?.restoringMetadata(from: other.fields.issuetype)))
    }

    static func newest(_ issues: [JiraIssue]) -> [JiraIssue] {
        var order: [String] = []
        var values: [String: JiraIssue] = [:]
        for issue in issues {
            if let previous = values[issue.id] { values[issue.id] = previous.accepting(issue, onEqual: false) }
            else { order.append(issue.id); values[issue.id] = issue }
        }
        return order.compactMap { values[$0] }
    }
}

private extension JiraIssue.NamedValue {
    func restoringMetadata(from other: JiraIssue.NamedValue?) -> JiraIssue.NamedValue {
        guard let other,
              id != nil && other.id != nil ? id == other.id : name == other.name else { return self }
        return JiraIssue.NamedValue(name: name, id: id ?? other.id, iconUrl: iconUrl ?? other.iconUrl,
                                    statusCategory: statusCategory ?? other.statusCategory)
    }
}

private enum IssueRevision {
    static let fractional = formatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ")
    static let seconds = formatter("yyyy-MM-dd'T'HH:mm:ssZ")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func date(_ value: String) -> Date? {
        fractional.date(from: value) ?? seconds.date(from: value)
    }
}

extension CachedSearch {
    public func reconciling(_ issues: [JiraIssue]) -> CachedSearch {
        var result = self
        let known = Dictionary(uniqueKeysWithValues: JiraIssue.newest(issues).map { ($0.id, $0) })
        result.issueOverrides = issueOverrides ?? [:]
        for issue in self.issues {
            if let newer = known[issue.id] { result.issueOverrides?[issue.id] = issue.accepting(newer) }
        }
        return result
    }
}

extension CachedIssueDetail {
    public func reconciling(_ latest: JiraIssue, preferOnEqual: Bool = true) -> CachedIssueDetail {
        guard issue.id == latest.id else { return self }
        let winner = issue.listIssue.accepting(latest, onEqual: preferOnEqual)
        var result = self
        result.issue = issue.replacingListFields(winner)
        return result
    }
}

extension JiraIssueDetail {
    fileprivate func replacingListFields(_ latest: JiraIssue) -> JiraIssueDetail {
        var result = self
        result.fields = Fields(summary: latest.fields.summary, description: fields.description,
            status: latest.fields.status, assignee: latest.fields.assignee, reporter: fields.reporter,
            priority: latest.fields.priority, issuetype: latest.fields.issuetype, resolution: fields.resolution,
            created: fields.created, updated: latest.fields.updated, duedate: fields.duedate,
            labels: fields.labels, components: fields.components, fixVersions: fields.fixVersions,
            comment: fields.comment, subtasks: fields.subtasks, issuelinks: fields.issuelinks, attachment: fields.attachment)
        return result
    }
}

extension JiraClient {
    /// Verify a conflicting index result without downloading comments and rendered descriptions.
    func issueSummary(site: JiraSite, token: String, id: String) async throws -> JiraIssue {
        guard Self.validIssueIdentifier(id) else { throw JiraError.invalidResponse }
        let response = try await fetch("issue/\(id)", site: site, token: token, queryItems: [
            URLQueryItem(name: "fields", value: "summary,status,assignee,priority,updated,issuetype")
        ])
        let issue: JiraIssue = try decode(response)
        guard issue.id == id || issue.key == id else { throw JiraError.invalidResponse }
        return issue
    }
}
