import AppKit
import XCTest
@testable import Kocro

final class KocroSmokeTests: XCTestCase {
    func testIdentity() {
        XCTAssertNotNil(KocroApp.self)
    }

    func testAppDeclaresAppIcon() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
            "AppIcon"
        )
    }

    func testMenuBarIconUsesEighteenPointCanvas() throws {
        let icon = try XCTUnwrap(NSImage(contentsOf: menuBarIconURL))

        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
    }

    func testMenuBarIconArtworkHasBalancedPadding() throws {
        let icon = try XCTUnwrap(NSImage(contentsOf: menuBarIconURL))
        let pixelSize = 72
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelSize,
                pixelsHigh: pixelSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()

        var minX = pixelSize
        var minY = pixelSize
        var maxX = -1
        var maxY = -1
        for y in 0..<pixelSize {
            for x in 0..<pixelSize where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        XCTAssertGreaterThanOrEqual(maxX, minX)
        XCTAssertLessThanOrEqual(abs(minX - (pixelSize - 1 - maxX)), 2)
        XCTAssertLessThanOrEqual(abs(minY - (pixelSize - 1 - maxY)), 2)
    }

    private var menuBarIconURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kocro/Resources/Assets.xcassets/MenuBarIcon.imageset/menu-bar-icon.svg")
    }
}
