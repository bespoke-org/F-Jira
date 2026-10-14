import Foundation

public struct JiraStatusCategory: Codable, Sendable {
    public let key: String?
    public let colorName: String?

    public var tone: JiraStatusTone {
        switch key?.lowercased() {
        case "new": return .neutral
        case "indeterminate", "in-flight": return .inProgress
        case "done", "completed": return .done
        default:
            switch colorName?.lowercased() {
            case "yellow": return .inProgress
            case "green": return .done
            default: return .neutral
            }
        }
    }
}

public enum JiraStatusTone: String, CaseIterable, Sendable {
    case neutral
    case inProgress = "in-progress"
    case done

    public func palette(dark: Bool) -> JiraStatusPalette {
        switch (self, dark) {
        case (.neutral, false): .init(foreground: 0x42526E, background: 0xEBECF0)
        case (.neutral, true): .init(foreground: 0xB6C2CF, background: 0x2C333A)
        case (.inProgress, false): .init(foreground: 0x0747A6, background: 0xDEEBFF)
        case (.inProgress, true): .init(foreground: 0x85B8FF, background: 0x1C3A5E)
        case (.done, false): .init(foreground: 0x216E4E, background: 0xDCFFF1)
        case (.done, true): .init(foreground: 0x7EE2B8, background: 0x164B35)
        }
    }
}

public struct JiraStatusPalette: Sendable {
    public let foreground: UInt32
    public let background: UInt32
    public var borderOpacity: Double { 0.25 }
    public var borderWidth: Double { 0.5 }
    var borderCSS: String {
        "rgba(\((foreground >> 16) & 0xFF), \((foreground >> 8) & 0xFF), \(foreground & 0xFF), \(borderOpacity))"
    }
    var foregroundCSS: String { String(format: "#%06x", foreground) }
    var backgroundCSS: String { String(format: "#%06x", background) }
}
