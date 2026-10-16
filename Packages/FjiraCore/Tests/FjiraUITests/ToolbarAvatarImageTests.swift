import AppKit
import FjiraUI
import XCTest

@MainActor
final class ToolbarAvatarImageTests: XCTestCase {
    func testNativeMenuReceivesCircularRetinaImageWithoutMutatingSharedSource() throws {
        let source = NSImage(size: NSSize(width: 80, height: 60), flipped: false) { bounds in
            NSColor.red.setFill()
            bounds.fill()
            return true
        }
        let image = try XCTUnwrap(ToolbarAvatarImage.image(from: source))
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
        XCTAssertEqual(source.size, NSSize(width: 80, height: 60))
        XCTAssertFalse(image.isTemplate)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 48)
        XCTAssertEqual(bitmap.pixelsHigh, 48)
        for (x, y) in [(0, 0), (47, 0), (0, 47), (47, 47)] {
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
        }
        let center = try XCTUnwrap(bitmap.colorAt(x: 24, y: 24)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(center.alphaComponent, 1)
        XCTAssertEqual(center.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 24, y: 3)).alphaComponent, 1,
                       "Non-square avatars must fill the circle without letterboxing")
        XCTAssertTrue(ToolbarAvatarImage.image(from: source) === image, "Reuse the prepared menu image")
        XCTAssertNil(ToolbarAvatarImage.image(from: NSImage(size: .zero)))
    }
}
