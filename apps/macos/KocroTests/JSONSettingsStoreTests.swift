import Foundation
import XCTest
@testable import Kocro

final class JSONSettingsStoreTests: XCTestCase {
    func testReservedShortcutLoadMigrationDisablesAndPreservesMacro() throws {
        let before = MacroDefinition(id: UUID(), title: "기존 복사 단축키", isEnabled: true,
            shortcut: .init(key: .keyCode(8), modifiers: .command),
            text: "보존할 문자열", trailingKey: .enter)
        let file = MemorySettingsFile(contents: try JSONEncoder().encode(AppSettings(macros: [before])))
        let loaded = try JSONSettingsStore(file: file, validator: .init()).load()
        XCTAssertEqual(loaded.macros[0].id, before.id)
        XCTAssertEqual(loaded.macros[0].title, before.title)
        XCTAssertEqual(loaded.macros[0].shortcut, before.shortcut)
        XCTAssertEqual(loaded.macros[0].steps, before.steps)
        XCTAssertFalse(loaded.macros[0].isEnabled)
    }

    func testF21ThroughF24LoadMigrationPreservesMacroContentAndOrder() throws {
        for number in 21...24 {
            let before = AppSettings(macros: [Fixtures.carbon(13),
                MacroDefinition(id: UUID(), title: "기존 F\(number)", isEnabled: true,
                    shortcut: .init(key: .function(number), modifiers: []),
                    text: "보존할 문자열", trailingKey: .custom(keyCode: 0, modifiers: .shift)),
                Fixtures.carbon(14)])
            let file = MemorySettingsFile(contents: try JSONEncoder().encode(before))
            let loaded = try JSONSettingsStore(file: file, validator: .init()).load()
            XCTAssertEqual(loaded.macros.map(\.id), before.macros.map(\.id))
            XCTAssertEqual(loaded.macros[1].title, before.macros[1].title)
            XCTAssertEqual(loaded.macros[1].steps, before.macros[1].steps)
            XCTAssertFalse(loaded.macros[1].isEnabled)
            XCTAssertEqual(loaded.macros[1].shortcut, .init(key: .empty, modifiers: []))
            XCTAssertEqual(loaded.macros[0].shortcut, before.macros[0].shortcut)
            XCTAssertEqual(loaded.macros[2].shortcut, before.macros[2].shortcut)
        }
    }

    func testLegacyMacrosWithoutTitlesMigrateByOrderAndWriteTitlesOnNextSave() throws {
        let legacy = AppSettings(macros: [
            MacroDefinition(id: UUID(), isEnabled: true,
                shortcut: .init(key: .function(13), modifiers: []), text: "첫째", trailingKey: .enter),
            MacroDefinition(id: UUID(), isEnabled: false,
                shortcut: .init(key: .empty, modifiers: []), text: "둘째",
                trailingKey: .custom(keyCode: 0, modifiers: .shift))])
        let data = try legacyData(legacy, texts: ["첫째", "둘째"],
            trailingKeys: [.enter, .custom(keyCode: 0, modifiers: .shift)], removeTitles: true)
        let file = MemorySettingsFile(contents: data)
        let store = JSONSettingsStore(file: file, validator: .init())
        let loaded = try store.load()
        XCTAssertEqual(loaded.macros.map(\.id), legacy.macros.map(\.id))
        XCTAssertEqual(loaded.macros.map(\.isEnabled), [true, false])
        XCTAssertEqual(loaded.macros.map(\.shortcut), legacy.macros.map(\.shortcut))
        XCTAssertEqual(loaded.macros.map { $0.steps.map(\.kind) }, [
            [.text("첫째"), .keys(.init(keyCode: 36, modifiers: []))],
            [.text("둘째"), .keys(.init(keyCode: 0, modifiers: .shift))]])
        try store.save(loaded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(file.contents)) as? [String: Any])
        let savedMacros = try XCTUnwrap(saved["macros"] as? [[String: Any]])
        XCTAssertEqual(savedMacros.compactMap { $0["title"] as? String }, ["매크로 1", "매크로 2"])
        for macro in savedMacros {
            XCTAssertNotNil(macro["steps"])
            XCTAssertNil(macro["text"])
            XCTAssertNil(macro["trailingKey"])
        }
        XCTAssertEqual(try store.load(), loaded)
    }

    func testStepsRoundTripPreservesIDsOrderUnicodeKeysAndDelays() throws {
        let steps: [MacroStep] = [
            .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
            .init(kind: .delay(milliseconds: 500)),
            .init(kind: .text("한글 👨‍👩‍👧‍👦\nCafe\u{301}")),
            .init(kind: .delay(milliseconds: 0)),
            .init(kind: .keys(.init(keyCode: 9, modifiers: [.command, .shift]))),
            .init(kind: .delay(milliseconds: 60_000))]
        let settings = AppSettings(macros: [MacroDefinition(id: UUID(), title: "순서", isEnabled: true,
            shortcut: .init(key: .function(13), modifiers: []), steps: steps)])
        let file = MemorySettingsFile(contents: nil)
        let store = JSONSettingsStore(file: file, validator: .init())
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        XCTAssertEqual(try store.load().macros[0].steps.map(\.id), steps.map(\.id))
    }

    func testLegacyEmptyTextDoesNotCreateTextStep() throws {
        let settings = AppSettings(macros: [MacroDefinition.newDraft(), MacroDefinition.newDraft()])
        let data = try legacyData(settings, texts: ["", ""], trailingKeys: [nil, .tab])
        let loaded = try JSONSettingsStore(file: MemorySettingsFile(contents: data), validator: .init()).load()
        XCTAssertTrue(loaded.macros[0].steps.isEmpty)
        XCTAssertEqual(loaded.macros[1].steps.map(\.kind), [.keys(.init(keyCode: 48, modifiers: []))])
    }

    func testPresentStepsTakePrecedenceOverLegacyFieldsIncludingEmptySteps() throws {
        let settings = AppSettings(macros: [MacroDefinition.newDraft(), Fixtures.carbon(13)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
        for index in macros.indices {
            macros[index]["text"] = "must not replace steps"
            macros[index]["trailingKey"] = ["enter": [:]]
        }
        object["macros"] = macros
        let file = MemorySettingsFile(contents: try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try JSONSettingsStore(file: file, validator: .init()).load(), settings)
    }

    func testMalformedPresentStepsFailInsteadOfFallingBackToLegacyText() throws {
        for invalidSteps: Any in [NSNull(), "invalid", [["kind": "unknown"]]] {
            let settings = AppSettings(macros: [MacroDefinition.newDraft()])
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
            macros[0]["steps"] = invalidSteps
            macros[0]["text"] = "legacy"
            object["macros"] = macros
            let file = MemorySettingsFile(contents: try JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try JSONSettingsStore(file: file, validator: .init()).load())
        }
    }

    func testMissingRoundTripPreservesOrderUnicodeAndPermissions() throws {
        let file = MemorySettingsFile(contents: nil)
        let store = JSONSettingsStore(file: file, validator: .init())
        let defaults = try store.load()
        var reversed = AppSettings(macros: Array(defaults.macros.reversed()))
        reversed.macros[0] = reversed.macros[0].withText("한글 👨‍👩‍👧‍👦\nCafe\u{301}")
        try store.save(reversed)
        XCTAssertEqual(try store.load(), reversed)
        XCTAssertEqual(file.permissions, 0o600)
        XCTAssertEqual(file.replaceCount, 2)
    }

    func testEditedTitlesRoundTripWithoutNormalization() throws {
        var settings = AppSettings.defaults
        settings.macros[0].title = "  사용자 제목  "
        settings.macros[1].title = ""
        let file = MemorySettingsFile(contents: nil)
        let store = JSONSettingsStore(file: file, validator: .init())
        try store.save(settings)
        XCTAssertEqual(try store.load().macros.map(\.title), settings.macros.map(\.title))
    }

    func testPresentNonStringTitleFailsTheWholeLoad() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        let variants: [Any] = [NSNull(), 1, ["value": "매크로"]]
        for invalidTitle in variants {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
            macros[0]["title"] = invalidTitle
            object["macros"] = macros
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertThrowsError(try JSONSettingsStore(file: MemorySettingsFile(contents: data), validator: .init()).load()) {
                guard case StoreError.invalidFile = $0 else {
                    return XCTFail("StoreError.invalidFile이 필요합니다: \($0)")
                }
            }
        }
    }

    func testCorruptOrInvalidFileFailsTheWholeLoad() throws {
        let corrupt = MemorySettingsFile(contents: Data("{".utf8))
        XCTAssertThrowsError(try JSONSettingsStore(file: corrupt, validator: .init()).load()) {
            XCTAssertTrue($0 is StoreError)
        }
        var invalid = AppSettings.defaults
        invalid.macros[0] = invalid.macros[0].withText(String(repeating: "x", count: 10_001))
        let invalidData = try JSONEncoder().encode(invalid)
        XCTAssertThrowsError(try JSONSettingsStore(file: MemorySettingsFile(contents: invalidData), validator: .init()).load()) {
            XCTAssertTrue($0 is StoreError)
        }
        var unsupportedModifiers = AppSettings.defaults
        unsupportedModifiers.macros[0].isEnabled = true
        unsupportedModifiers.macros[0] = unsupportedModifiers.macros[0].withText("x")
        unsupportedModifiers.macros[0].shortcut = .init(key: .keyCode(0), modifiers: ModifierSet(rawValue: 0x10))
        let unsupportedData = try JSONEncoder().encode(unsupportedModifiers)
        XCTAssertThrowsError(try JSONSettingsStore(file: MemorySettingsFile(contents: unsupportedData), validator: .init()).load()) {
            XCTAssertTrue($0 is StoreError)
        }
        var unsupportedLetter = AppSettings.defaults
        unsupportedLetter.macros[0].isEnabled = true
        unsupportedLetter.macros[0] = unsupportedLetter.macros[0].withText("x")
        unsupportedLetter.macros[0].shortcut = .init(key: .letter("1"), modifiers: .command)
        let unsupportedLetterData = try JSONEncoder().encode(unsupportedLetter)
        XCTAssertThrowsError(try JSONSettingsStore(file: MemorySettingsFile(contents: unsupportedLetterData), validator: .init()).load()) {
            XCTAssertTrue($0 is StoreError)
        }
        let duplicateRepresentations = AppSettings(macros: [
            MacroDefinition(id: UUID(), isEnabled: true, shortcut: .init(key: .letter("B"), modifiers: .command), text: "x", trailingKey: nil),
            MacroDefinition(id: UUID(), isEnabled: true, shortcut: .init(key: .keyCode(11), modifiers: .command), text: "y", trailingKey: nil)])
        let duplicateData = try JSONEncoder().encode(duplicateRepresentations)
        XCTAssertThrowsError(try JSONSettingsStore(file: MemorySettingsFile(contents: duplicateData), validator: .init()).load()) {
            XCTAssertTrue($0 is StoreError)
        }
    }

    func testValidationAndWriteFailuresLeaveExistingBytesUnchanged() throws {
        let original = try JSONEncoder().encode(AppSettings.defaults)
        let file = MemorySettingsFile(contents: original)
        let store = JSONSettingsStore(file: file, validator: .init())
        var invalid = AppSettings.defaults
        invalid.macros[0] = invalid.macros[0].withText(String(repeating: "x", count: 10_001))
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(file.contents, original)
        XCTAssertEqual(file.replaceCount, 0)
        file.writeError = StoreError.io
        XCTAssertThrowsError(try store.save(.defaults))
        XCTAssertEqual(file.contents, original)
        XCTAssertEqual(file.replaceCount, 0)
    }

    func testApplicationSupportFileHandlesInitialSaveAndExistingReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KocroTests-\(UUID().uuidString)", isDirectory: true)
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

    private func legacyData(_ settings: AppSettings, texts: [String], trailingKeys: [TrailingKey?], removeTitles: Bool = false) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
        for index in macros.indices {
            macros[index].removeValue(forKey: "steps")
            macros[index]["text"] = texts[index]
            if let key = trailingKeys[index] {
                macros[index]["trailingKey"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(key))
            } else {
                macros[index].removeValue(forKey: "trailingKey")
            }
            if removeTitles { macros[index].removeValue(forKey: "title") }
        }
        object["macros"] = macros
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
