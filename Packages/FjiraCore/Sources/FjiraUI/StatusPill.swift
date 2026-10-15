import FjiraCore
import SwiftUI

public struct StatusPill: View {
    let name: String
    let tone: JiraStatusTone
    @Environment(\.colorScheme) private var colorScheme

    public init(name: String, tone: JiraStatusTone) {
        self.name = name
        self.tone = tone
    }

    public var body: some View {
        let palette = tone.palette(dark: colorScheme == .dark)
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .frame(minHeight: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color(palette.foreground))
            .background(color(palette.background), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(color(palette.foreground).opacity(palette.borderOpacity), lineWidth: palette.borderWidth)
            }
            .help(name)
            .accessibilityLabel(name)
    }

    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}
