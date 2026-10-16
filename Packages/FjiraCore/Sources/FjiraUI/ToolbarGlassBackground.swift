import AppKit
import SwiftUI

/// Matches the AppKit glass used by native toolbar items without joining adjacent controls.
@available(macOS 26.0, *)
public struct ToolbarGlassBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSGlassEffectView {
        let view = ToolbarGlassView()
        view.style = .regular
        return view
    }

    public func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}

@available(macOS 26.0, *)
private final class ToolbarGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        cornerRadius = min(bounds.width, bounds.height) / 2
    }
}
