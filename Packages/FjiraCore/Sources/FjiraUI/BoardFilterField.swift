import AppKit
import SwiftUI

public struct BoardFilterField: View {
    @Binding private var text: String

    public init(text: Binding<String>) {
        _text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            TextField("Filter cards", text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(width: 150)
        .background(FilterFocusBoundary())
        .help("Filter downloaded cards by issue key or title")
    }
}

private struct FilterFocusBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> FilterFocusBoundaryView { FilterFocusBoundaryView() }
    func updateNSView(_ nsView: FilterFocusBoundaryView, context: Context) {}

    static func dismantleNSView(_ nsView: FilterFocusBoundaryView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class FilterFocusBoundaryView: NSView {
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopMonitoring()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissEditingIfOutside(event)
            }
            return event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func dismissEditingIfOutside(_ event: NSEvent) {
        guard let window, event.window === window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField,
              bounds.contains(convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field)),
              !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // Passive board content does not take first responder away from a toolbar text field.
        // End editing before dispatch so another clicked control can still receive focus.
        window.makeFirstResponder(nil)
    }
}
