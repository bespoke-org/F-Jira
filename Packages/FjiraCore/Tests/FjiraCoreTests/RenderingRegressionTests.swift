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
