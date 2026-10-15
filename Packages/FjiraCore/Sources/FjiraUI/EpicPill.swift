import FjiraCore
import SwiftUI

public struct EpicPill: View {
    let epic: JiraEpicLink
    @Environment(\.colorScheme) private var colorScheme

    public init(epic: JiraEpicLink) { self.epic = epic }

    public var body: some View {
        let palette = JiraEpicPalette(colorKey: epic.color?.key).palette(dark: colorScheme == .dark)
        Text(epic.pillTitle)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .frame(minHeight: 12)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color(palette.foreground))
            .background(color(palette.background), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(color(palette.foreground).opacity(palette.borderOpacity), lineWidth: palette.borderWidth)
            }
            .help("\(epic.displayName) (\(epic.key))")
            .accessibilityLabel("Epic: \(epic.displayName)")
    }

    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}
