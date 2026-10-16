import AppKit

/// Native menu labels extract NSImage directly, bypassing SwiftUI sizing and clipping.
@MainActor
public enum ToolbarAvatarImage {
    private static let cache: NSCache<NSImage, NSImage> = {
        let cache = NSCache<NSImage, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    public static func image(from source: NSImage) -> NSImage? {
        if let cached = cache.object(forKey: source) { return cached }
        guard source.size.width > 0, source.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let size = CGSize(width: 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 48, height: 48))
        context.cgContext.scaleBy(x: 2, y: 2)
        NSBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
        let scale = max(size.width / source.size.width, size.height / source.size.height)
        let drawnSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        source.draw(in: CGRect(x: (size.width - drawnSize.width) / 2,
                               y: (size.height - drawnSize.height) / 2,
                               width: drawnSize.width, height: drawnSize.height))
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        cache.setObject(image, forKey: source)
        return image
    }
}
