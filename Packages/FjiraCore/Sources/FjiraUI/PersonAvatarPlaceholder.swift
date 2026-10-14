import AppKit

@MainActor
public enum PersonAvatarPlaceholder {
    public static let symbolName = "person.crop.circle"
    private static let lightDataURL = render(dark: false)
    private static let darkDataURL = render(dark: true)

    public static func dataURL(dark: Bool) -> String? {
        dark ? darkDataURL : lightDataURL
    }

    private static func render(dark: Bool) -> String? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let size = NSSize(width: 20, height: 20)
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) else { return }
            // An explicit 2x bitmap keeps the 20-point HTML avatar sharp on Retina.
            let scale = 2.0
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            let symbolSize = symbol.size
            symbol.draw(in: NSRect(x: (size.width - symbolSize.width) / 2,
                                   y: (size.height - symbolSize.height) / 2,
                                   width: symbolSize.width, height: symbolSize.height))
            data = bitmap.representation(using: .png, properties: [:])
        }
        return data.map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}
