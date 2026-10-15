import SwiftUI

public struct IssueFlagIndicator: View {
    public init() {}

    public var body: some View {
        Image(systemName: "flag.fill")
            .foregroundStyle(.red)
            .help("Flagged")
            .accessibilityLabel("Flagged")
    }
}
