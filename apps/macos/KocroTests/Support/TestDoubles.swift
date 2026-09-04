import Foundation
@testable import Kocro

final class MemorySettingsFile: SettingsFile {
    var contents: Data?
    var permissions: Int16?
    var replaceCount = 0
    var writeError: Error?

    init(contents: Data?) {
        self.contents = contents
    }

    var exists: Bool { contents != nil }

    func read() throws -> Data {
        guard let contents else { throw StoreError.io }
        return contents
    }

    func atomicReplace(with data: Data, permissions: Int16) throws {
        if let writeError { throw writeError }
        contents = data
        self.permissions = permissions
        replaceCount += 1
    }
}

enum Fixtures {
    static func macro(
        id: UUID = UUID(),
        text: String,
        shortcut: ShortcutDefinition = .init(key: .function(13), modifiers: [])
    ) -> MacroDefinition {
        .init(id: id, isEnabled: true, shortcut: shortcut, text: text, trailingKey: nil)
    }

    static func settings(text: String) -> AppSettings {
        .init(macros: [macro(text: text)])
    }

    static func carbon(_ number: Int) -> MacroDefinition {
        macro(text: "c\(number)", shortcut: .init(key: .function(number), modifiers: []))
    }

    static func hid(_ number: Int) -> MacroDefinition {
        macro(text: "h\(number)", shortcut: .init(key: .function(number), modifiers: []))
    }

    static func enabledCarbonCarbonHID() -> [MacroDefinition] {
        [carbon(13), carbon(14), hid(21)]
    }
}
