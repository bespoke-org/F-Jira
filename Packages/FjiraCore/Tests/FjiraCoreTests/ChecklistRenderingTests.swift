import Foundation
import XCTest
@testable import FjiraCore

final class ChecklistRenderingTests: XCTestCase {
    func testJiraWikiAndMarkdownChecklistMarkers() {
        let html = JiraRichText.wiki("h3. Definition of Done\r\n * [ ] Проведен анализ поведения счётчика\r\n * [x] Сформулированы выводы\r\n- [X] *Ready*\n* Ordinary bullet")
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 3)
        XCTAssertEqual(html.components(separatedBy: " disabled checked").count - 1, 2)
        XCTAssertTrue(html.contains("Проведен анализ поведения счётчика"))
        XCTAssertTrue(html.contains("<strong>Ready</strong>"))
        XCTAssertTrue(html.contains("<li>Ordinary bullet</li>"))
        XCTAssertFalse(html.contains("href=\" \""))
    }

    func testRenderedJiraListsAndParagraphLines() {
        let html = JiraRichText.rendered("<ul>\n\t<li>[ ] Проведен анализ поведения счётчика</li>\n\t<li>[x] <strong>Сформулированы выводы</strong></li></ul><p>- [ ] First<br/>- [X] Second</p>")
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 4)
        XCTAssertEqual(html.components(separatedBy: " disabled checked").count - 1, 2)
        XCTAssertTrue(html.contains("<strong>Сформулированы выводы</strong>"))
        XCTAssertFalse(html.contains("[ ]"))
    }

    func testJiraErrorSpansWithEncodedChecklistBrackets() {
        let html = JiraRichText.rendered(#"<div class="panelContent"><ul><li><span class="error">&#91;x&#93;</span> Completed</li><li><span class="error">&#x5b;X&#x5d;</span> Also completed</li><li>&lbrack; &rbrack; Pending &lt;example&gt;</li></ul></div>"#)
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 3)
        XCTAssertEqual(html.components(separatedBy: " disabled checked").count - 1, 2)
        XCTAssertTrue(html.contains("Pending &lt;example&gt;"), "Only the checklist marker should interpret entities")
        let code = #"<pre>* &#91;x&#93; Code</pre><p><tt>* &#91;x&#93; Inline code</tt></p>"#
        XCTAssertEqual(JiraRichText.rendered(code), code)
        XCTAssertFalse(JiraRichText.wiki("* &#91;x&#93; Literal wiki text").contains("type=\"checkbox\""))
    }

    func testMarkersInsideCodeLinksAndMidSentenceStayLiteral() {
        let html = #"<pre>- [ ] Code</pre><p><code>- [x] Inline code</code></p><p>Example: - [ ] text</p><a href="https://example.com/[x]">- [ ] Link</a><p data-example="- [ ] Attribute">Text</p>"#
        XCTAssertEqual(JiraRichText.rendered(html), html)
        let wiki = JiraRichText.wiki("{code}\n- [ ] Code\n{code}\n{{- [x] Inline code}}")
        XCTAssertFalse(wiki.contains("type=\"checkbox\""))
        XCTAssertTrue(wiki.contains("- [ ] Code"))
        XCTAssertTrue(wiki.contains("- [x] Inline code"))
    }

    func testDescriptionAndCommentBothRenderReadOnlyCheckboxes() async throws {
        for rendered in [false, true] {
            let source = rendered ? "<ul><li>[ ] Description</li></ul>" : "* [ ] Description"
            var object: [String: Any] = ["id": "100", "key": "EX-1", "fields": [
                "summary": "Checklist", "description": source,
                "comment": ["comments": [["id": "1", "body": "- [x] Comment"]]]
            ]]
            if rendered {
                object["renderedFields"] = ["description": source,
                    "comment": ["comments": [["id": "1", "body": "<p>- [x] Comment</p>"]]]]
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let detail = try await JiraClient(transport: StubTransport([(200, json)]))
                .issue(site: JiraSite("https://jira.example.com"), token: "fixture", id: "100")
            for dark in [false, true] {
                let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com")!, dark: dark)
                XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 2)
                XCTAssertEqual(html.components(separatedBy: " disabled").count - 1, 2)
            }
        }
    }
}
