import Foundation

public enum JiraRichText {
    public static func rendered(_ html: String) -> String {
        let tokenizer = try! NSRegularExpression(pattern: #"<[^>]*>|[^<]+|<"#)
        var protectedDepth = 0
        let rendered = tokenizer.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
            let token = String(html[Range(match.range, in: html)!])
            if token.hasPrefix("<") {
                let lowered = token.lowercased()
                for tag in ["pre", "code", "script", "style"] {
                    if lowered.range(of: "^<\\s*\(tag)\\b", options: .regularExpression) != nil { protectedDepth += 1 }
                    if lowered.range(of: "^</\\s*\(tag)\\b", options: .regularExpression) != nil { protectedDepth = max(0, protectedDepth - 1) }
                }
                return token
            }
            guard protectedDepth == 0, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return token }
            return literalBreaks(token).replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>\n")
        }.joined()
        return renderChecklists(normalizeSpacing(rendered))
    }

    public static func wiki(_ source: String) -> String {
        var blocks: [String: String] = [:]
        let expression = try! NSRegularExpression(pattern: #"\{(code|noformat)(?::([^}]*))?\}([\s\S]*?)\{\1\}"#)
        var text = source
        let tokenPrefix = UUID().uuidString
        for (index, match) in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).enumerated().reversed() {
            let token = "BLOCK-\(tokenPrefix)-\(index)"
            let body = String(source[Range(match.range(at: 3), in: source)!])
            let language = Range(match.range(at: 2), in: source).map { String(source[$0]).filter { $0.isLetter || $0.isNumber || $0 == "-" } } ?? ""
            blocks[token] = "<pre><code class=\"language-\(language)\">\(IssueBodyHTML.escape(body.trimmingCharacters(in: .newlines)))</code></pre>"
            text.replaceSubrange(Range(match.range, in: text)!, with: "\n\(token)\n")
        }
        text = normalizeOutsideInlineCode(text).replacingOccurrences(of: "\r\n", with: "\n")
        var output = ""
        var list: String?
        var table = false
        func closeList() { if let kind = list { output += "</\(kind)>"; list = nil } }
        func closeTable() { if table { output += "</tbody></table>"; table = false } }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); closeTable(); continue }
            if let block = blocks[line] { closeList(); closeTable(); output += block; continue }
            if line.hasPrefix("|") && line.hasSuffix("|") {
                closeList()
                if !table { output += "<table><tbody>"; table = true }
                let header = line.hasPrefix("||")
                let separator = header ? "||" : "|"
                let cells = line.components(separatedBy: separator).dropFirst().dropLast()
                let tag = header ? "th" : "td"
                output += "<tr>" + cells.map { "<\(tag)>\(inline($0.trimmingCharacters(in: .whitespaces)))</\(tag)>" }.joined() + "</tr>"
                continue
            }
            closeTable()
            if let match = line.range(of: #"^(?:[*#]+|-(?=\s+\[[ xX]\](?:\s|$)))\s+"#, options: .regularExpression) {
                let kind = line.first == "#" ? "ol" : "ul"
                if list != kind { closeList(); output += "<\(kind)>"; list = kind }
                let body = String(line[match.upperBound...])
                if let item = checklistPrefix(body, allowBare: true) {
                    output += "<li class=\"task-list-item\">\(item.checkbox) \(inline(item.body))</li>"
                } else {
                    output += "<li>\(inline(body))</li>"
                }
                continue
            }
            closeList()
            if let range = line.range(of: #"^h[1-6]\.\s+"#, options: .regularExpression) {
                let level = line[line.index(after: line.startIndex)]
                output += "<h\(level)>\(inline(String(line[range.upperBound...])))</h\(level)>"
            } else if line.hasPrefix("bq. ") {
                output += "<blockquote>\(inline(String(line.dropFirst(4))))</blockquote>"
            } else { output += "<p>\(inline(line))</p>" }
        }
        closeList(); closeTable()
        return output
    }

    private static let htmlTokens = try! NSRegularExpression(pattern: #"<(?:[^>"']|"[^"]*"|'[^']*')*>|[^<]+|<"#)
    private static let htmlTagName = try! NSRegularExpression(pattern: #"^<\s*/?\s*([a-zA-Z0-9]+)"#)
    private static let taskMarker = try! NSRegularExpression(pattern: #"^(?:\s|&nbsp;|&#160;)*(?:([-*])(?:\s|&nbsp;|&#160;)+)?\[([ xX])\](?:(?:\s|&nbsp;|&#160;)+|$)"#)

    private static let renderedTaskMarker = try! NSRegularExpression(pattern: #"^(?:\s|&nbsp;|&#160;)*(?:([-*])(?:\s|&nbsp;|&#160;)+)?(?:\[|&#0*91;|&#[xX]0*5[bB];|&lbrack;)([ xX])(?:\]|&#0*93;|&#[xX]0*5[dD];|&rbrack;)(?:(?:\s|&nbsp;|&#160;)+|$)"#)

    private static func checklistPrefix(_ text: String, allowBare: Bool, rendered: Bool = false) -> (checkbox: String, body: String)? {
        let marker = rendered ? renderedTaskMarker : taskMarker
        guard let match = marker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              allowBare || match.range(at: 1).location != NSNotFound,
              let range = Range(match.range, in: text),
              let state = Range(match.range(at: 2), in: text) else { return nil }
        let checked = text[state].lowercased() == "x"
        let checkbox = "<input class=\"task-checkbox\" type=\"checkbox\" disabled\(checked ? " checked" : "") aria-label=\"\(checked ? "Completed" : "Not completed")\">"
        return (checkbox, String(text[range.upperBound...]))
    }

    private static func renderChecklists(_ html: String) -> String {
        var protectedDepth = 0
        var listDepth = 0
        var lineStart = true
        return htmlTokens.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
            let token = String(html[Range(match.range, in: html)!])
            if token.hasPrefix("<") {
                guard let tagMatch = htmlTagName.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
                      let nameRange = Range(tagMatch.range(at: 1), in: token) else { return token }
                let name = token[nameRange].lowercased()
                let closing = token.range(of: #"^<\s*/"#, options: .regularExpression) != nil
                if ["pre", "code", "tt", "script", "style", "a"].contains(name) {
                    protectedDepth = max(0, protectedDepth + (closing ? -1 : 1))
                    lineStart = false
                }
                if protectedDepth == 0 {
                    if name == "li" { listDepth = max(0, listDepth + (closing ? -1 : 1)) }
                    if ["li", "p", "div", "br", "ul", "ol", "blockquote"].contains(name) { lineStart = true }
                }
                return token
            }
            guard protectedDepth == 0 else { return token }
            let item = lineStart ? checklistPrefix(token, allowBare: listDepth > 0, rendered: true) : nil
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lineStart = false }
            if let item { return item.checkbox + " " + item.body }
            return token
        }.joined()
    }

    private static let codeBlocks = try! NSRegularExpression(
        pattern: #"<(pre|code)\b(?:[^>"']|"[^"]*"|'[^']*')*>[\s\S]*?</\1\s*>"#, options: .caseInsensitive)

    private static let spacingRules: [(NSRegularExpression, String)] = {
        let blank = #"(?:\s|&nbsp;|&#(?:0*160|0*32|0*10|0*13);|&#x(?:0*a0|0*20|0*a|0*d);)"#
        let br = #"<br\b(?:[^>"']|"[^"]*"|'[^']*')*>"#
        let rules = [
            (#"<(p|div)\b(?:[^>"']|"[^"]*"|'[^']*')*>(?:"# + blank + "|" + br + #")*</\1\s*>"#, ""),
            ("(?:" + br + blank + "*){2,}", "<br>"),
            (#"(</(?:p|div)\s*>)(?:"# + blank + "|" + br + #")+(<(?:p|div)\b)"#, "$1$2"),
            (#"(<(?:p|div)\b(?:[^>"']|"[^"]*"|'[^']*')*>)(?:"# + blank + "|" + br + ")+", "$1"),
            ("(?:" + blank + "|" + br + #")+(?=</(?:p|div)\s*>)"#, ""),
            ("^(?:" + blank + "|" + br + ")+|(?:" + blank + "|" + br + ")+$", "")
        ]
        return rules.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    private static func normalizeSpacing(_ html: String) -> String {
        // Keep preformatted and inline code out of prose whitespace normalization.
        var text = html
        var preserved: [(String, String)] = []
        let prefix = "FJIRA-CODE-" + UUID().uuidString + "-"
        for (index, match) in codeBlocks.matches(in: html, range: NSRange(html.startIndex..., in: html)).enumerated().reversed() {
            guard let range = Range(match.range, in: html) else { continue }
            let token = prefix + String(index)
            preserved.append((token, String(html[range])))
            text.replaceSubrange(range, with: token)
        }
        // Repeat to remove nested empty wrappers exposed by the previous pass.
        var previous: String
        repeat {
            previous = text
            for (rule, replacement) in spacingRules {
                text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
        } while text != previous
        for (token, code) in preserved { text = text.replacingOccurrences(of: token, with: code) }
        return text
    }

    private static func inline(_ text: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{\{[^\n]*?\}\}|\[[^\n\]]+\]|(?<!\w)\*[^*\n]+\*(?!\w)|(?<!\w)_[^_\n]+_(?!\w)"#)
        var output = ""
        var cursor = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = Range(match.range, in: text)!
            output += IssueBodyHTML.escape(String(text[cursor..<range.lowerBound]))
            let token = String(text[range])
            if token.hasPrefix("{{") {
                output += "<code>\(IssueBodyHTML.escape(String(token.dropFirst(2).dropLast(2))))</code>"
            } else if token.first == "*" {
                output += "<strong>\(IssueBodyHTML.escape(String(token.dropFirst().dropLast())))</strong>"
            } else if token.first == "_" {
                output += "<em>\(IssueBodyHTML.escape(String(token.dropFirst().dropLast())))</em>"
            } else {
                let parts = token.dropFirst().dropLast().split(separator: "|", maxSplits: 1).map(String.init)
                let label = parts[0]
                var target = parts.last!
                if parts.count == 1, target.range(of: #"^[A-Z][A-Z0-9_]*-[0-9]+$"#, options: .regularExpression) != nil { target = "browse/\(target)" }
                let scheme = URLComponents(string: target)?.scheme?.lowercased()
                if ["https", "http", "mailto"].contains(scheme ?? "") || (scheme == nil && !target.hasPrefix("//")) {
                    output += "<a href=\"\(IssueBodyHTML.escape(target))\">\(IssueBodyHTML.escape(label))</a>"
                } else { output += IssueBodyHTML.escape(token) }
            }
            cursor = range.upperBound
        }
        return output + IssueBodyHTML.escape(String(text[cursor...]))
    }

    private static func normalizeOutsideInlineCode(_ text: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{\{.*?\}\}"#, options: .dotMatchesLineSeparators)
        var output = ""
        var cursor = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = Range(match.range, in: text)!
            output += literalBreaks(String(text[cursor..<range.lowerBound])) + text[range]
            cursor = range.upperBound
        }
        return output + literalBreaks(String(text[cursor...]))
    }

    private static func literalBreaks(_ text: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"(?<![:\\])\\(?:r\\n|n|r)"#)
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
    }
}
