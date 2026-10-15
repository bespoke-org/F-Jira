import Foundation

public enum IssueBodyHTML {
    public static func document(detail: CachedIssueDetail, baseURL: URL, dark: Bool, avatars: [String: CachedAvatar] = [:], issueLinksError: String? = nil, personPlaceholderDataURL: String? = nil, activityTab: IssueActivityTab = .comments, historyIsLoading: Bool = false, historyError: String? = nil, historyLimit: Int = 50) -> String {
        func rendered(_ html: String) -> String {
            JiraRichText.rendered(JiraRichTextImages.embedding(html, baseURL: baseURL, images: avatars))
        }
        let description = detail.issue.renderedFields?.description.map(rendered)
            ?? JiraRichText.wiki(detail.issue.fields.description ?? "No description.")
        let currentIDs = Set(detail.currentComments.map(\.id))
        // Explicit String results prevent GRDB's SQL interpolation from capturing HTML.
        let comments: String = detail.comments.map { comment -> String in
            let body = detail.renderedBody(for: comment).map(rendered) ?? JiraRichText.wiki(comment.body ?? "")
            let name = comment.authorName
            let avatar = avatarMarkup(name: name, url: comment.author?.avatarURL, className: "avatar", images: avatars)
            return """
                <article class="comment">
                    <header class="comment-header">\(avatar)<div>
                    <div class="author-name">\(escape(name))</div>
                    <div class="muted">\(escape(comment.created.map(date) ?? ""))
                    \(currentIDs.contains(comment.id) ? "" : " · Previously downloaded")</div>
                    </div></header>
                    \(body)
                </article>
                """
        }.joined(separator: "\n")
        let background = dark ? "#1e1e1e" : "#ffffff"
        let foreground = dark ? "#eeeeee" : "#222222"
        let statusStyles: String = JiraStatusTone.allCases.map { tone -> String in
            let palette = tone.palette(dark: dark)
            return ".status-\(tone.rawValue) { color: \(palette.foregroundCSS); background: \(palette.backgroundCSS); box-shadow: inset 0 0 0 \(palette.borderWidth)px \(palette.borderCSS); }"
        }.joined(separator: "\n")
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none';">
            <base href="\(escape(baseURL.absoluteString + "/"))">
            <style>
            html, body { margin: 0; padding: 0; background: \(background); color: \(foreground); }
            body { padding: 16px; box-sizing: border-box; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.5; overflow-wrap: anywhere; }
            h1 { font-size: 20px; line-height: 1.3; margin: 0 0 18px; }
            .metadata { display: grid; grid-template-columns: 90px minmax(0, 1fr); gap: 7px 14px; margin-bottom: 14px; }
            hr { border: 0; border-top: 1px solid rgba(128,128,128,.3); margin: 18px 0; }
            .status-pill, .chip, .epic-pill { border-radius: \(IssuePillStyle.cornerRadius)px; }
            .status-pill { display: inline-flex; align-items: center; max-width: 100%; box-sizing: border-box; padding: 3px 8px; font-size: 12px; font-weight: 500; line-height: 16px; }
            .status-pill > span, .epic-pill > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .epic-pill { display: inline-flex; max-width: 100%; box-sizing: border-box; padding: 3px 8px; font-size: 12px; font-weight: 500; line-height: 16px; text-decoration: none; vertical-align: middle; }
            \(statusStyles)
            .metadata dt { opacity: .65; } .metadata dd { margin: 0; }
            .chips { display: flex; flex-wrap: wrap; gap: 6px; margin: 0; }
            .tag-label { padding-top: 2px; }
            .chip { display: inline-block; border: 1px solid rgba(128,128,128,.35); background: rgba(128,128,128,.12); padding: 2px 8px; }
            .muted { opacity: .65; font-size: 12px; }
            .related { display: block; padding: 6px 0; }
            .issue-link-label { margin-right: 6px; }
            h2 { font-size: 16px; margin: 18px 0 10px; }
            h2:first-child { margin-top: 0; }
            a { color: \(dark ? "#75baff" : "#0066cc"); }
            pre, code, tt { font-family: Menlo, monospace; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; padding: 10px; background: rgba(128,128,128,.12); border-radius: 6px; }
            table { border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: 1px solid #888; padding: 6px; }
            img { max-width: 100%; height: auto; }
            img.emoticon, img.emoji { width: 16px; height: 16px; vertical-align: text-bottom; }
            blockquote { border-left: 3px solid #888; margin-left: 0; padding-left: 12px; }
            .activity { margin-top: 20px; border: 1px solid rgba(128,128,128,.3); border-radius: 10px; overflow: hidden; }
            .activity-tabs { display: flex; gap: 8px; padding: 0 12px; background: rgba(128,128,128,.06); border-bottom: 1px solid rgba(128,128,128,.25); }
            .activity-tab { display: inline-block; padding: 10px 8px; border-bottom: 2px solid transparent; text-decoration: none; color: inherit; opacity: .65; }
            .activity-tab[aria-selected="true"] { opacity: 1; border-bottom-color: currentColor; color: \(dark ? "#75baff" : "#0066cc"); font-weight: 600; }
            .activity-tab:focus-visible { outline: 2px solid currentColor; outline-offset: -4px; border-radius: 4px; }
            .activity-panel { padding: 0 14px; }
            .comment, .history-entry { border-top: 1px solid rgba(128,128,128,.2); padding: 14px 0; }
            .activity-panel > article:first-child { border-top: 0; }
            .history-change { margin: 10px 0; }
            .history-values { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 12px; margin-top: 4px; }
            .history-value { white-space: pre-wrap; margin-top: 3px; padding: 6px 8px; border-radius: 5px; background: rgba(128,128,128,.09); }
            @media (max-width: 460px) { .history-values { grid-template-columns: minmax(0, 1fr); gap: 4px; } }
            .comment-header { display: flex; gap: 10px; align-items: center; margin: 0 0 12px; }
            .author-name { font-size: 14px; font-weight: 600; }
            .avatar { width: 36px; height: 36px; flex: 0 0 36px; border-radius: 50%; object-fit: cover; }
            .metadata-value { display: flex; gap: 7px; align-items: center; min-height: 20px; }
            .metadata-icon { width: 16px; height: 16px; flex: 0 0 16px; object-fit: contain; }
            .metadata-avatar { width: 20px; height: 20px; flex: 0 0 20px; font-size: 10px; }
            .initials { display: inline-flex; align-items: center; justify-content: center; background: #436a96; color: #fff; font-size: 13px; font-weight: 600; }
            .metadata-avatar.initials { font-size: 10px; }
            code { background: rgba(128,128,128,.12); padding: 1px 4px; border-radius: 3px; }
            pre code { background: none; padding: 0; }
            </style></head><body>
            \(metadata(detail, dark: dark, images: avatars, personPlaceholderDataURL: personPlaceholderDataURL))
            <hr class="description-divider">
            \(description)
            \(issueLinks(detail, error: issueLinksError))
            \(relations(detail, baseURL: baseURL))
            \(activity(detail, comments: comments, tab: activityTab, loading: historyIsLoading,
                       error: historyError, limit: historyLimit, images: avatars, baseURL: baseURL))
            </body></html>
            """
    }

    private static func activity(_ detail: CachedIssueDetail, comments: String, tab: IssueActivityTab,
                                 loading: Bool, error: String?, limit: Int, images: [String: CachedAvatar], baseURL: URL) -> String {
        let issueID = escape(detail.issue.id)
        let tabs: String = [IssueActivityTab.comments, .history].map { item -> String in
            let name = item == .comments ? "Comments" : "History"
            return "<a id=\"activity-\(item.rawValue)-tab\" class=\"activity-tab\" role=\"tab\" tabindex=\"\(item == tab ? 0 : -1)\" aria-selected=\"\(item == tab)\" aria-controls=\"activity-panel\" href=\"fjira://activity/\(item.rawValue)?issue=\(issueID)\">\(name)</a>"
        }.joined()
        let content: String
        if tab == .comments {
            content = (comments.isEmpty ? "<p class=\"muted\">No comments yet.</p>" : comments)
                + (detail.hasPreviousComments ? "<p class=\"muted\">Some comments are from an earlier download.</p>" : "")
                + (detail.hasMoreComments ? "<p><a href=\"fjira://comments/more\">Load more comments</a></p>" : "")
        } else {
            let history = detail.history
            var result = ""
            if loading { result += "<p class=\"muted\" role=\"status\">\(history == nil ? "Loading history…" : "Updating history…")</p>" }
            if let error {
                result += "<p class=\"muted\" role=\"status\">\(escape(error)) <a href=\"fjira://history/retry?issue=\(issueID)\">Retry</a></p>"
                if let history { result += "<p class=\"muted\">Showing history downloaded \(escape(history.fetchedAt.formatted(date: .abbreviated, time: .shortened))).</p>" }
            }
            if let history {
                if history.entries.isEmpty && history.total == 0 { result += "<p class=\"muted\">No changes recorded yet.</p>" }
                for entry in history.newestFirst.prefix(max(1, limit)) {
                    let avatar = avatarMarkup(name: entry.authorName, url: entry.author?.avatarURL, className: "avatar", images: images)
                    let changes: String = entry.items.map { change -> String in
                        func value(_ text: String?, fallback: String?) -> String {
                            let value = text ?? fallback ?? ""
                            return value.isEmpty ? "<span class=\"muted\">None</span>" : escape(value)
                        }
                        return """
                            <div class="history-change"><strong>\(escape(change.field))</strong>
                            <div class="history-values"><div><span class="muted">From</span><div class="history-value">\(value(change.fromString, fallback: change.from))</div></div>
                            <div><span class="muted">To</span><div class="history-value">\(value(change.toString, fallback: change.to))</div></div></div></div>
                            """
                    }.joined()
                    result += """
                        <article class="history-entry"><header class="comment-header">\(avatar)<div>
                        <div class="author-name">\(escape(entry.authorName))</div><div class="muted">\(escape(entry.created.map(date) ?? ""))</div>
                        </div></header>\(changes)</article>
                        """
                }
                if history.entries.count > limit {
                    result += "<p><a href=\"fjira://history/more?issue=\(issueID)\">Show more changes</a></p>"
                }
                if history.entries.count < history.total {
                    result += "<p class=\"muted\">Jira returned \(history.entries.count) of \(history.total) changes. <a href=\"\(escape(baseURL.appending(path: "browse/\(detail.issue.key)").absoluteString))\">View full history in Jira</a>.</p>"
                }
            } else if !loading && error == nil {
                result += "<p class=\"muted\">History has not been downloaded yet. <a href=\"fjira://history/retry?issue=\(issueID)\">Load history</a></p>"
            }
            content = result
        }
        return """
            <section class="activity" aria-label="Issue activity" data-tab="\(tab.rawValue)">
            <div class="activity-tabs" role="tablist" aria-label="Activity">\(tabs)</div>
            <div id="activity-panel" class="activity-panel" role="tabpanel" aria-labelledby="activity-\(tab.rawValue)-tab">\(content)</div>
            </section>
            """
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func metadata(_ detail: CachedIssueDetail, dark: Bool, images: [String: CachedAvatar], personPlaceholderDataURL: String?) -> String {
        let issue = detail.issue.listIssue
        let fields = detail.issue.fields
        var rows = [
            ("Status", "<span class=\"status-pill status-\(issue.statusTone.rawValue)\" title=\"\(escape(issue.status))\"><span>\(escape(issue.status))</span></span>"),
            ("Type", iconValue(issue.issueType, url: fields.issuetype?.iconUrl, images: images)),
            ("Priority", iconValue(issue.priority, url: fields.priority?.iconUrl, images: images)),
            ("Assignee", personValue(fields.assignee, fallback: "Unassigned", images: images, placeholderDataURL: personPlaceholderDataURL))
        ]
        if detail.issue.hasImplementerField {
            rows.append(("Implementer", personValue(detail.issue.implementer, fallback: "Unassigned", images: images, placeholderDataURL: personPlaceholderDataURL)))
        }
        if let reporter = fields.reporter { rows.append(("Reporter", personValue(reporter, fallback: "Unknown", images: images, placeholderDataURL: personPlaceholderDataURL))) }
        if let epic = detail.issue.epicLink {
            let palette = JiraEpicPalette(colorKey: epic.color?.key).palette(dark: dark)
            rows.append(("Epic Link", "<a class=\"epic-pill\" href=\"fjira://epic/\(escape(epic.key))\" title=\"\(escape(epic.displayName)) (\(escape(epic.key)))\" style=\"background: \(palette.backgroundCSS); color: \(palette.foregroundCSS); box-shadow: inset 0 0 0 \(palette.borderWidth)px \(palette.borderCSS)\"><span>\(escape(epic.pillTitle))</span></a>"))
        }
        if let created = fields.created { rows.append(("Created", escape(date(created)))) }
        if let updated = fields.updated { rows.append(("Updated", escape(date(updated)))) }
        if let due = fields.duedate { rows.append(("Due", escape(due))) }
        if let resolution = fields.resolution { rows.append(("Resolution", escape(resolution.name))) }
        let grid: String = rows.map { row -> String in "<dt>\(escape(row.0))</dt><dd>\(row.1)</dd>" }.joined()
        let groups = [("Labels", fields.labels ?? []), ("Components", (fields.components ?? []).map(\.name)), ("Fix versions", (fields.fixVersions ?? []).map(\.name))]
        let chips: String = groups.filter { !$0.1.isEmpty }.map { title, names -> String in
            "<dt class=\"tag-label\">\(escape(title))</dt><dd><div class=\"chips\">" + names.map { name -> String in "<span class=\"chip\">\(escape(name))</span>" }.joined() + "</div></dd>"
        }.joined()
        return "<h1>\(escape(issue.summary))</h1><dl class=\"metadata\">\(grid)\(chips)</dl>"
    }

    private static func iconValue(_ name: String, url: URL?, images: [String: CachedAvatar]) -> String {
        let icon: String
        if let url, let cached = images[url.absoluteString] {
            icon = "<img class=\"metadata-icon\" src=\"\(cached.dataURL)\" alt=\"\(escape(name))\">"
        } else if url != nil {
            icon = "<span class=\"metadata-icon\" aria-hidden=\"true\"></span>"
        } else { icon = "" }
        return "<span class=\"metadata-value\">\(icon)<span>\(escape(name))</span></span>"
    }

    private static func personValue(_ user: JiraUser?, fallback: String, images: [String: CachedAvatar], placeholderDataURL: String?) -> String {
        guard let user else {
            let avatar = placeholderDataURL.map {
                "<img class=\"avatar metadata-avatar person-placeholder\" src=\"\(escape($0))\" alt=\"\" aria-hidden=\"true\">"
            } ?? ""
            return "<span class=\"metadata-value\">\(avatar)<span>\(escape(fallback))</span></span>"
        }
        let avatar = avatarMarkup(name: user.displayName, url: user.avatarURL,
                                  className: "avatar metadata-avatar", images: images)
        return "<span class=\"metadata-value\">\(avatar)<span>\(escape(user.displayName))</span></span>"
    }

    private static func avatarMarkup(name: String, url: URL?, className: String, images: [String: CachedAvatar]) -> String {
        if let url, let cached = images[url.absoluteString] {
            return "<img class=\"\(className)\" src=\"\(cached.dataURL)\" alt=\"\(escape(name))\">"
        }
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        let initials = parts.count > 1 ? parts.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.prefix(2))
        return "<span class=\"\(className) initials\" aria-label=\"\(escape(name))\">\(escape(initials.uppercased()))</span>"
    }

    private static func issueLinks(_ detail: CachedIssueDetail, error: String?) -> String {
        let jiraLinks: String = (detail.issue.fields.issuelinks ?? []).compactMap { item -> String? in
            item.relatedIssue.map { issue in
                "<div class=\"related\"><span class=\"muted issue-link-label\">\(escape(item.label))</span> <a href=\"fjira://issue/\(escape(issue.id))\">\(escape(issue.key)): \(escape(issue.summary))</a></div>"
            }
        }.joined()
        let remoteLinks: String = (detail.remoteLinks?.links ?? []).map { link -> String in
            let url = link.object.url
            let title = escape(link.object.title)
            let clickable = ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                && url.host != nil && url.user == nil && url.password == nil
            let anchor = clickable ? "<a href=\"\(escape(url.absoluteString))\">\(title)</a>" : title
            let context = [link.relationship, link.application?.name, link.object.status?.resolved == true ? "Resolved" : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
            let summary = link.object.summary.map { "<div class=\"muted\">\(escape($0))</div>" } ?? ""
            let label = context.isEmpty ? "" : "<span class=\"muted issue-link-label\">\(context)</span> "
            return "<div class=\"remote-link related\">\(label)\(anchor)\(summary)</div>"
        }.joined()
        let notice = error.map { "<p class=\"muted\">\(escape($0))</p>" } ?? ""
        guard !jiraLinks.isEmpty || !remoteLinks.isEmpty || error != nil else { return "" }
        return "<h2>Issue Links</h2>" + jiraLinks + remoteLinks + notice
    }

    private static func relations(_ detail: CachedIssueDetail, baseURL: URL) -> String {
        func link(_ issue: JiraIssue) -> String {
            "<a class=\"related\" href=\"fjira://issue/\(escape(issue.id))\">\(escape(issue.key)): \(escape(issue.summary))</a>"
        }
        var result = ""
        if let tasks = detail.issue.fields.subtasks, !tasks.isEmpty { result += "<h2>Subtasks</h2>" + tasks.map(link).joined() }
        if let attachments = detail.issue.fields.attachment, !attachments.isEmpty {
            result += "<h2>Attachments</h2><ul>" + attachments.map { "<li>\(escape($0.filename))</li>" }.joined() + "</ul>"
            result += "<a href=\"\(escape(baseURL.appending(path: "browse/\(detail.issue.key)").absoluteString))\">View attachments in Jira</a>"
        }
        return result
    }

    private static func date(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

}
