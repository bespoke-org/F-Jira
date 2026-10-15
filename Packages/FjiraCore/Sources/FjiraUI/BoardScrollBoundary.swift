import AppKit
import SwiftUI

/// Place inside a board scroll view's content to stop overscroll at its edges.
struct BoardScrollBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

    func updateNSView(_ view: BoundaryView, context: Context) {
        view.apply()
        // SwiftUI can update the enclosing scroll view later in the same pass.
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }

    final class BoundaryView: NSView {
        private weak var boundedClip: NSClipView?
        private weak var boundedDocument: NSView?
        private var isClamping = false

        private func installBoundary(_ scroll: NSScrollView) {
            let clip = scroll.contentView
            let document = scroll.documentView
            if boundedClip !== clip || boundedDocument !== document {
                if let boundedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: boundedClip) }
                if let boundedDocument { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: boundedDocument) }
                boundedClip = clip
                boundedDocument = document
                clip.postsBoundsChangedNotifications = true
                document?.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(clampBounds), name: NSView.boundsDidChangeNotification, object: clip)
                if let document {
                    NotificationCenter.default.addObserver(self, selector: #selector(clampBounds), name: NSView.frameDidChangeNotification, object: document)
                }
            }
            clampBounds()
        }

        // Momentum can move SwiftUI's clip view past its edges even with elasticity disabled.
        // Enforce the bounds synchronously, before drawing, while respecting safe-area insets.
        @objc private func clampBounds() {
            guard !isClamping, let clip = boundedClip, let document = boundedDocument else { return }
            let bounds = clip.bounds
            let insets = clip.contentInsets
            let minX = document.frame.minX - insets.left
            let minY = document.frame.minY - (clip.isFlipped ? insets.top : insets.bottom)
            let maxX = max(minX, document.frame.maxX + insets.right - bounds.width)
            let maxY = max(minY, document.frame.maxY + (clip.isFlipped ? insets.bottom : insets.top) - bounds.height)
            let origin = NSPoint(x: min(max(bounds.minX, minX), maxX), y: min(max(bounds.minY, minY), maxY))
            guard origin != bounds.origin else { return }
            isClamping = true
            defer { isClamping = false }
            clip.setBoundsOrigin(origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .none
            installBoundary(scrollView)
        }
    }
}
