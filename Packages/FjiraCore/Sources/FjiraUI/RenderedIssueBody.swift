import AppKit
import SwiftUI
import WebKit

public struct RenderedIssueBody: NSViewRepresentable {
    let document: String?
    let documentID: String?
    let onAction: (URL) -> Void

    public init(document: String?, documentID: String? = nil, onAction: @escaping (URL) -> Void = { _ in }) {
        self.document = document
        self.documentID = documentID
        self.onAction = onAction
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onAction: onAction) }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAction = onAction
        context.coordinator.update(webView, document: document, id: documentID)
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        private var desiredDocument: String?
        private var desiredID: String?
        private var renderedDocument: String?
        private var renderedID: String?
        private var isReady = false
        private var isUpdating = false
        var onAction: (URL) -> Void
        init(onAction: @escaping (URL) -> Void) { self.onAction = onAction }

        func update(_ webView: WKWebView, document: String?, id: String?) {
            // A cache read can be pending between selections. Keep the last body visible.
            guard let document else { return }
            desiredDocument = document
            desiredID = id
            if renderedDocument == nil {
                renderedDocument = document
                renderedID = id
                webView.loadHTMLString(document, baseURL: nil)
            } else {
                applyLatest(to: webView)
            }
        }

        private func applyLatest(to webView: WKWebView) {
            guard isReady, !isUpdating, let desiredDocument,
                  desiredDocument != renderedDocument || desiredID != renderedID else { return }
            isUpdating = true
            let id = desiredID
            // Parse offscreen, then replace the whole tree in one browser turn. Navigating
            // with loadHTMLString would clear the old issue before the next one is ready.
            webView.callAsyncJavaScript("""
                const offset = resetScroll ? 0 : window.scrollY;
                const parsed = new DOMParser().parseFromString(html, 'text/html');
                const replacement = document.importNode(parsed.documentElement, true);
                document.documentElement.replaceWith(replacement);
                window.scrollTo(0, offset);
                """, arguments: ["html": desiredDocument, "resetScroll": id != renderedID],
                in: nil, in: .defaultClient) { [weak self, weak webView] result in
                    guard let self, let webView else { return }
                    self.isUpdating = false
                    switch result {
                    case .success:
                        self.renderedDocument = desiredDocument
                        self.renderedID = id
                        self.applyLatest(to: webView)
                    case .failure:
                        // Recover if WebKit's content process has exited.
                        self.isReady = false
                        self.renderedDocument = self.desiredDocument
                        self.renderedID = self.desiredID
                        webView.loadHTMLString(self.desiredDocument ?? desiredDocument, baseURL: nil)
                    }
                }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            applyLatest(to: webView)
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                if url.scheme == "fjira" { onAction(url) }
                else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                return .cancel
            }
            return url.scheme == "about" ? .allow : .cancel
        }
    }
}
