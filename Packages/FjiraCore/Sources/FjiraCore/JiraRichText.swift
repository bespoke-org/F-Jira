import Foundation

public enum JiraRichText {
    public static func rendered(_ html: String) -> String {
        let tokenizer = try! NSRegularExpression(pattern: #"<[^>]*>|[^<]+|<"#)
        var protectedDepth = 0
        return tokenizer.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
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
            if let match = line.range(of: #"^[*#]+\s+"#, options: .regularExpression) {
                let kind = line.first == "#" ? "ol" : "ul"
                if list != kind { closeList(); output += "<\(kind)>"; list = kind }
                output += "<li>\(inline(String(line[match.upperBound...])))</li>"
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
