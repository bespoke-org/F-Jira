import Foundation
import XCTest
@testable import FjiraCore

final class RenderingRegressionTests: XCTestCase {
    func testLiteralNewlinesBecomeParagraphBreaksInRenderedProse() async throws {
        let detail = try await fixture(description: #"<p>First\nSecond</p>"#, rendered: true)
        let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertFalse(html.contains(#"First\nSecond"#), "Prose must not display literal newline escapes")
        XCTAssertTrue(html.contains("First<br") || html.contains("First\nSecond"))
    }

    func testRawJiraWikiUsesHeadingsListsAndCodeBlocks() async throws {
        let detail = try await fixture(description: "h3. Heading\n* One\n* Two\n{code:rust}\nlet x = 1;\n{code}", rendered: false)
        let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertTrue(html.contains("<h3>Heading</h3>"))
        XCTAssertTrue(html.contains("<li>One</li>"))
        XCTAssertTrue(html.contains("<code"))
        XCTAssertFalse(html.contains("{code:rust}"))
    }

    func testCommentHeaderFallsBackToUsername() async throws {
        let detail = try await fixture(description: "Text", rendered: false)
        let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertTrue(html.contains("alice"), "Every comment must identify its author even when displayName is absent")
    }

    func testLiteralEscapesInsideCodeRemainLiteral() {
        let rendered = JiraRichText.rendered(#"<p>One\nTwo</p><pre><code>print("\n")</code></pre>"#)
        XCTAssertTrue(rendered.contains(#"print("\n")"#))
        XCTAssertFalse(rendered.contains(#"One\nTwo"#))
        let wiki = JiraRichText.wiki("{code:rust}\n" + #"let newline = "\n";"# + "\n{code}")
        XCTAssertTrue(wiki.contains(#"&quot;\n&quot;"#))
    }

    func testHTMLNeverContainsDatabaseExpressionDebugOutput() async throws {
        let detail = try await fixture(description: "Text", rendered: false)
        let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertFalse(html.contains("SQL(elements:"), "HTML interpolation must use String, never a database expression")
        XCTAssertTrue(html.contains("<article class=\"comment\">"))
    }

    func testRenderedTextTrimsWhitespaceAndEmptyBoundaryParagraphs() {
        let html = "  \n<p>&nbsp;<br></p><div>  </div><p>  <br> Actual text &nbsp;<br><br> </p><p>&#160;</p>\n  "
        XCTAssertEqual(JiraRichText.rendered(html), "<p>Actual text</p>")
        XCTAssertEqual(JiraRichText.rendered(" \n Text \n "), "Text")
        XCTAssertEqual(JiraRichText.rendered("<p>&nbsp;<br></p>"), "")
    }

    func testRepeatedBlankLinesBecomeOneBreak() {
        XCTAssertEqual(JiraRichText.rendered("<p>First\n\n\nSecond</p>"), "<p>First<br>Second</p>")
        XCTAssertEqual(JiraRichText.rendered("<p>First<br><br /> &nbsp;<br>Second</p>"), "<p>First<br>Second</p>")
        XCTAssertEqual(JiraRichText.rendered("<p>First</p><p><br></p><p>&nbsp;</p><br><br><p>Second</p>"),
                       "<p>First</p><p>Second</p>")
        XCTAssertEqual(JiraRichText.wiki("\n First\n\n\nSecond \n"), "<p>First</p><p>Second</p>")
    }

    func testWhitespaceNormalizationPreservesCodeAndInteriorSpaces() {
        let code = "<pre><code>  first\n\n\n  second  \n</code></pre>"
        XCTAssertEqual(JiraRichText.rendered("<p><br></p>\n" + code + "\n<p>&nbsp;</p>"), code)
        XCTAssertEqual(JiraRichText.rendered("<p>Start <code>  x\n\n  y  </code> end</p>"),
                       "<p>Start <code>  x\n\n  y  </code> end</p>")
        XCTAssertEqual(JiraRichText.rendered("<p>One  two</p>"), "<p>One  two</p>")
        XCTAssertEqual(JiraRichText.rendered("<p><img class='emoticon' src='data:image/gif;base64,abc' alt=':)'></p>"),
                       "<p><img class='emoticon' src='data:image/gif;base64,abc' alt=':)'></p>")
    }

    private func fixture(description: String, rendered: Bool) async throws -> CachedIssueDetail {
        var object: [String: Any] = [
            "id": "100", "key": "EX-1", "fields": [
                "summary": "Fixture", "description": description,
                "comment": ["comments": [["id": "c1", "body": "Comment", "author": ["name": "alice"]]]]
            ]
        ]
        if rendered { object["renderedFields"] = ["description": description] }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await JiraClient(transport: StubTransport([(200, String(decoding: data, as: UTF8.self))]))
            .issue(site: JiraSite("https://jira.example.com"), token: "fixture-token", id: "100")
    }
}
