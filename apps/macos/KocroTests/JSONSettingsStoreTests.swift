import Foundation
import XCTest
@testable import Kocro

final class JSONSettingsStoreTests: XCTestCase {
    func testMissingRoundTripPreservesOrderUnicodeAndPermissions() throws {
        let file = MemorySettingsFile(contents: nil)
        let store = JSONSettingsStore(file: file, validator: .init())

        let defaults = try store.load()
        var reversed = AppSettings(macros: Array(defaults.macros.reversed()))
        reversed.macros[0].text = "한글 👨‍👩‍👧‍👦\nCafe\u{301}"
        try store.save(reversed)

        XCTAssertEqual(try store.load(), reversed)
        XCTAssertEqual(file.permissions, 0o600)
        XCTAssertEqual(file.replaceCount, 2)
    }

    func testCorruptOrInvalidFileFailsTheWholeLoad() throws {
        let corrupt = MemorySettingsFile(contents: Data("{".utf8))
        XCTAssertThrowsError(try JSONSettingsStore(file: corrupt, validator: .init()).load()) {
            XCTAssertTrue($0 is StoreError)
        }

        var invalid = AppSettings.defaults
        invalid.macros[0].text = String(repeating: "x", count: 10_001)
        let invalidData = try JSONEncoder().encode(invalid)
        XCTAssertThrowsError(
            try JSONSettingsStore(file: MemorySettingsFile(contents: invalidData), validator: .init()).load()
        ) {
            XCTAssertTrue($0 is StoreError)
        }

        var unsupportedModifiers = AppSettings.defaults
        unsupportedModifiers.macros[0].isEnabled = true
        unsupportedModifiers.macros[0].text = "x"
        unsupportedModifiers.macros[0].shortcut = .init(
            key: .keyCode(0),
            modifiers: ModifierSet(rawValue: 0x10)
        )
        let unsupportedData = try JSONEncoder().encode(unsupportedModifiers)
        XCTAssertThrowsError(
            try JSONSettingsStore(
                file: MemorySettingsFile(contents: unsupportedData),
                validator: .init()
            ).load()
        ) {
            XCTAssertTrue($0 is StoreError)
        }

        var unsupportedLetter = AppSettings.defaults
        unsupportedLetter.macros[0].isEnabled = true
        unsupportedLetter.macros[0].text = "x"
        unsupportedLetter.macros[0].shortcut = .init(
            key: .letter("1"),
            modifiers: .command
        )
        let unsupportedLetterData = try JSONEncoder().encode(unsupportedLetter)
        XCTAssertThrowsError(
            try JSONSettingsStore(
                file: MemorySettingsFile(contents: unsupportedLetterData),
                validator: .init()
            ).load()
        ) {
            XCTAssertTrue($0 is StoreError)
        }
    }

    func testValidationAndWriteFailuresLeaveExistingBytesUnchanged() throws {
        let original = try JSONEncoder().encode(AppSettings.defaults)
        let file = MemorySettingsFile(contents: original)
        let store = JSONSettingsStore(file: file, validator: .init())

        var invalid = AppSettings.defaults
        invalid.macros[0].text = String(repeating: "x", count: 10_001)
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(file.contents, original)
        XCTAssertEqual(file.replaceCount, 0)

        file.writeError = StoreError.io
        XCTAssertThrowsError(try store.save(.defaults))
        XCTAssertEqual(file.contents, original)
        XCTAssertEqual(file.replaceCount, 0)
    }

    func testApplicationSupportFileHandlesInitialSaveAndExistingReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KocroTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = ApplicationSupportSettingsFile(applicationSupportDirectory: root)

        try file.atomicReplace(with: Data("first".utf8), permissions: 0o600)
        XCTAssertEqual(try file.read(), Data("first".utf8))
        XCTAssertEqual(permissions(at: file.parentDirectoryURL), 0o700)
        XCTAssertEqual(permissions(at: file.url), 0o600)

        try file.atomicReplace(with: Data("second".utf8), permissions: 0o600)
        XCTAssertEqual(try file.read(), Data("second".utf8))
        XCTAssertEqual(permissions(at: file.url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.parentDirectoryURL.path), ["settings.json"])
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
