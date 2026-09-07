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
}

final class MenuBarIconTests: XCTestCase {
    func testMenuBarIconUsesEighteenPointCanvas() throws {
        let icon = try XCTUnwrap(NSImage(named: "MenuBarIcon"))

        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(icon.isTemplate)
    }

    func testMenuBarIconArtworkHasBalancedPadding() throws {
        let icon = try XCTUnwrap(NSImage(named: "MenuBarIcon"))
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
        let margins = [minX, minY, pixelSize - 1 - maxX, pixelSize - 1 - maxY]
        margins.forEach { XCTAssertTrue(4...12 ~= $0, "Unexpected artwork margin: \($0)px") }
        XCTAssertTrue(54...62 ~= maxX - minX + 1)
        XCTAssertTrue(57...63 ~= maxY - minY + 1)
        XCTAssertLessThanOrEqual(abs(margins[0] - margins[2]), 2)
        XCTAssertLessThanOrEqual(abs(margins[1] - margins[3]), 2)
    }
}

final class SettingsSourceLayoutTests: XCTestCase {
    func testCollapsedShortcutBlocksStayInPrimaryHeaderRow() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kocro/Features/Settings/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)
        let macroCard = try XCTUnwrap(source.range(of: "private struct MacroCard: View"))
        let header = try XCTUnwrap(
            source.range(of: "HStack(spacing: 8) {", range: macroCard.lowerBound..<source.endIndex)
        )
        let shortcutBlocks = try XCTUnwrap(
            source.range(of: "CollapsedShortcutBlocks(", range: header.lowerBound..<source.endIndex)
        )
        let trailingControls = try XCTUnwrap(
            source.range(of: "Spacer()", range: header.lowerBound..<source.endIndex)
        )

        XCTAssertLessThan(shortcutBlocks.lowerBound, trailingControls.lowerBound)
    }
}
