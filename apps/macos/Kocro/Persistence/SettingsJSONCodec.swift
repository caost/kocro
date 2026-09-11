import Foundation

/// Settings files and macro transfers share the same format and load migrations.
struct SettingsJSONCodec {
    let validator: SettingsValidator

    func decode(_ data: Data) throws -> AppSettings {
        let persisted = try JSONDecoder().decode(PersistedAppSettings.self, from: data)
        var decoded = AppSettings(
            macros: persisted.macros.enumerated().map { index, macro in
                macro.definition(defaultTitle: "매크로 \(index + 1)")
            }
        )
        for index in decoded.macros.indices
        where decoded.macros[index].shortcut.usesRemovedFunctionKey {
            decoded.macros[index].isEnabled = false
            decoded.macros[index].shortcut = .init(key: .empty, modifiers: [])
        }
        for index in decoded.macros.indices
        where ReservedShortcutPolicy.contains(decoded.macros[index].shortcut) {
            decoded.macros[index].isEnabled = false
        }
        return try validator.validate(decoded)
    }

    func encode(_ value: AppSettings) throws -> Data {
        let valid = try validator.validate(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(valid)
    }
}

private struct PersistedAppSettings: Decodable {
    let macros: [PersistedMacroDefinition]
}

private struct PersistedMacroDefinition: Decodable {
    let id: UUID
    let title: String?
    let isEnabled: Bool
    let shortcut: ShortcutDefinition
    let text: String
    let trailingKey: TrailingKey?

    private enum CodingKeys: String, CodingKey {
        case id, title, isEnabled, shortcut, text, trailingKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = container.contains(.title)
            ? try container.decode(String.self, forKey: .title)
            : nil
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        shortcut = try container.decode(ShortcutDefinition.self, forKey: .shortcut)
        text = try container.decode(String.self, forKey: .text)
        trailingKey = try container.decodeIfPresent(TrailingKey.self, forKey: .trailingKey)
    }

    func definition(defaultTitle: String) -> MacroDefinition {
        MacroDefinition(
            id: id,
            title: title ?? defaultTitle,
            isEnabled: isEnabled,
            shortcut: shortcut,
            text: text,
            trailingKey: trailingKey
        )
    }
}
