import XCTest
@testable import Kocro

final class SettingsValidatorTests: XCTestCase {
    let validator = SettingsValidator()

    func testDefaultsAndOrder() throws {
        let value = AppSettings.defaults

        XCTAssertEqual(value.macros.map(\.shortcut.key), (13...24).map { .function($0) })
        XCTAssertEqual(Set(value.macros.map(\.id)).count, 12)
        XCTAssertTrue(value.macros.allSatisfy { !$0.isEnabled && $0.text.isEmpty })
        XCTAssertNoThrow(try validator.validate(value))

        let reversed = AppSettings(macros: Array(value.macros.reversed()))
        XCTAssertEqual(
            try validator.validate(reversed).macros.map(\.id),
            Array(value.macros.reversed()).map(\.id)
        )

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(reversed)
        )
        XCTAssertEqual(decoded.macros.map(\.id), reversed.macros.map(\.id))
    }

    func testIdentityLengthAndEnabledValues() {
        let id = UUID()
        let shortcut = ShortcutDefinition(key: .function(13), modifiers: [])
        let valid = MacroDefinition(
            id: id,
            isEnabled: true,
            shortcut: shortcut,
            text: "가",
            trailingKey: .enter
        )

        XCTAssertThrowsError(try validator.validate(.init(macros: [valid, valid])))

        let duplicateShortcut = MacroDefinition(
            id: UUID(),
            isEnabled: true,
            shortcut: shortcut,
            text: "나",
            trailingKey: nil
        )
        XCTAssertThrowsError(
            try validator.validate(.init(macros: [valid, duplicateShortcut]))
        )
        XCTAssertThrowsError(
            try validator.validate(
                .init(macros: [valid.withText(String(repeating: "x", count: 10_001))])
            )
        )
        XCTAssertNoThrow(
            try validator.validate(
                .init(macros: [valid.withText(String(repeating: "👨‍👩‍👧‍👦", count: 10_000))])
            )
        )
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid.withText("")])))
    }

    func testShortcutMatrixAndDuplicates() {
        XCTAssertThrowsError(
            try validator.validateShortcut(.init(key: .letter("a"), modifiers: []))
        )
        XCTAssertNoThrow(
            try validator.validateShortcut(.init(key: .letter("a"), modifiers: [.command]))
        )
        XCTAssertNoThrow(
            try validator.validateShortcut(.init(key: .keyCode(0), modifiers: [.control]))
        )
        XCTAssertNoThrow(
            try validator.validateShortcut(.init(key: .function(1), modifiers: [.command]))
        )
        XCTAssertThrowsError(
            try validator.validateShortcut(.init(key: .function(1), modifiers: []))
        )

        for number in 13...24 {
            XCTAssertNoThrow(
                try validator.validateShortcut(.init(key: .function(number), modifiers: []))
            )
        }
        for number in 13...20 {
            XCTAssertNoThrow(
                try validator.validateShortcut(.init(key: .function(number), modifiers: [.shift]))
            )
        }
        for number in 21...24 {
            XCTAssertThrowsError(
                try validator.validateShortcut(.init(key: .function(number), modifiers: [.shift]))
            )
        }
        for number in 25...35 {
            XCTAssertThrowsError(
                try validator.validateShortcut(.init(key: .function(number), modifiers: []))
            )
        }

        XCTAssertThrowsError(
            try validator.validateShortcut(.init(key: .letter("ab"), modifiers: [.command]))
        )
        XCTAssertThrowsError(
            try validator.validateShortcut(.init(key: .keyCode(55), modifiers: [.command]))
        )

        let unsupported = ModifierSet(rawValue: ModifierSet.command.rawValue | 0x10)
        XCTAssertThrowsError(
            try validator.validateShortcut(.init(key: .keyCode(0), modifiers: unsupported))
        )
    }

    func testTrailingKeyMatrix() {
        XCTAssertNoThrow(try validator.validateTrailing(.enter))
        XCTAssertNoThrow(try validator.validateTrailing(.space))
        XCTAssertNoThrow(try validator.validateTrailing(.tab))
        XCTAssertNoThrow(
            try validator.validateTrailing(.custom(keyCode: 0, modifiers: [.shift]))
        )
        XCTAssertThrowsError(
            try validator.validateTrailing(.custom(keyCode: nil, modifiers: [.option]))
        )
        XCTAssertThrowsError(
            try validator.validateTrailing(.custom(keyCode: 56, modifiers: []))
        )
        XCTAssertThrowsError(
            try validator.validateTrailing(
                .custom(keyCode: 0, modifiers: ModifierSet(rawValue: 0x10))
            )
        )
        for number in 21...35 {
            XCTAssertThrowsError(try validator.validateTrailing(.customFunction(number)))
        }
    }

    func testRawKeyPolicyRejectsVolumeKeysAndAcceptsEveryKeypadDigit() {
        for volumeKeyCode: UInt16 in [72, 73, 74] {
            XCTAssertThrowsError(
                try validator.validateShortcut(
                    .init(key: .keyCode(volumeKeyCode), modifiers: .command)
                )
            )
            XCTAssertThrowsError(
                try validator.validateTrailing(
                    .custom(keyCode: volumeKeyCode, modifiers: [])
                )
            )
        }

        let keypadDigits: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for keyCode in keypadDigits {
            XCTAssertNoThrow(
                try validator.validateShortcut(
                    .init(key: .keyCode(keyCode), modifiers: .control)
                )
            )
            XCTAssertNoThrow(
                try validator.validateTrailing(
                    .custom(keyCode: keyCode, modifiers: [])
                )
            )
        }
    }

    func testRawKeyPolicyAcceptsStableJISKeys() {
        for keyCode: UInt16 in [93, 94, 95] {
            XCTAssertNoThrow(
                try validator.validateShortcut(
                    .init(key: .keyCode(keyCode), modifiers: .command)
                )
            )
            XCTAssertNoThrow(
                try validator.validateTrailing(
                    .custom(keyCode: keyCode, modifiers: [])
                )
            )
        }
    }

    func testInactiveDraftsAllowEmptyAndDuplicateShortcuts() {
        let shortcut = ShortcutDefinition(key: .empty, modifiers: [])
        let settings = AppSettings(
            macros: (0..<100).map { _ in
                MacroDefinition(
                    id: UUID(),
                    isEnabled: false,
                    shortcut: shortcut,
                    text: "",
                    trailingKey: nil
                )
            }
        )

        XCTAssertNoThrow(try validator.validate(settings))
    }
}
