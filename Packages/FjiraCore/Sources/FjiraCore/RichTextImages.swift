import Foundation

// Resolve Jira's inline image tags once for downloading and again for embedding cached bytes.
enum JiraRichTextImages {
    private static let tags = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<img\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: .caseInsensitive)
    private static let attributes = try! NSRegularExpression(
        pattern: #"([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: .caseInsensitive)
    private static let entities = try! NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);"#,
                                                           options: .caseInsensitive)

    static func urls(in html: String, baseURL: URL) -> [URL] {
        var seen = Set<URL>()
        return imageTags(in: html).compactMap { range in
            let tag = String(html[range])
            guard let source = source(in: tag), let url = resolve(source, baseURL: baseURL),
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func embedding(_ html: String, baseURL: URL, images: [String: CachedAvatar]) -> String {
        var result = html
        for range in imageTags(in: html).reversed() {
            let tag = String(html[range])
            guard let source = source(in: tag), let url = resolve(source, baseURL: baseURL),
                  let image = images[url.absoluteString] else { continue }
            var updated = tag
            // A srcset must not override the cached src in the offline document.
            let replacements = attributeMatches(in: tag).compactMap { match -> (Range<String.Index>, String)? in
                let name = String(tag[Range(match.range(at: 1), in: tag)!]).lowercased()
                guard name == "src" || name == "srcset", let attributeRange = Range(match.range, in: tag) else { return nil }
                return (attributeRange, name == "src" ? "src=\"\(image.dataURL)\"" : "")
            }
            for (attributeRange, replacement) in replacements.reversed() {
                updated.replaceSubrange(attributeRange, with: replacement)
            }
            result.replaceSubrange(range, with: updated)
        }
        return result
    }

    private static func imageTags(in html: String) -> [Range<String.Index>] {
        tags.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html), !html[range].hasPrefix("<!--") else { return nil }
            return range
        }
    }

    private static func attributeMatches(in tag: String) -> [NSTextCheckingResult] {
        attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag))
    }

    private static func source(in tag: String) -> String? {
        for match in attributeMatches(in: tag) {
            guard String(tag[Range(match.range(at: 1), in: tag)!]).lowercased() == "src",
                  let valueRange = (2...4).compactMap({ Range(match.range(at: $0), in: tag) }).first else { continue }
            return String(tag[valueRange])
        }
        return nil
    }

    private static func resolve(_ source: String, baseURL: URL) -> URL? {
        let source = unescape(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, let base = URL(string: baseURL.absoluteString + "/"),
              let url = URL(string: source, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.host?.lowercased() == baseURL.host?.lowercased(),
              (url.port ?? 443) == (baseURL.port ?? 443) else { return nil }
        return url
    }

    private static func unescape(_ source: String) -> String {
        var result = source
        for match in entities.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: source), let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let name = source[nameRange].lowercased()
            let replacement: String?
            if name.hasPrefix("#") {
                let hex = name.hasPrefix("#x")
                replacement = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10)
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{00a0}"][name]
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
