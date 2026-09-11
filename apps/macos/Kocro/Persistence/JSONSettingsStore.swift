import Darwin
import Foundation

final class JSONSettingsStore: SettingsStoring {
    private let file: SettingsFile
    private let validator: SettingsValidator

    init(file: SettingsFile, validator: SettingsValidator) {
        self.file = file
        self.validator = validator
    }

    func load() throws -> AppSettings {
        guard file.exists else {
            let defaults = AppSettings.defaults
            try save(defaults)
            return defaults
        }

        do {
            let persisted = try JSONDecoder().decode(PersistedAppSettings.self, from: file.read())
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
        } catch {
            throw StoreError.invalidFile
        }
    }

    func save(_ value: AppSettings) throws {
        let valid = try validator.validate(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try file.atomicReplace(with: encoder.encode(valid), permissions: 0o600)
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
    let steps: [MacroStep]

    private enum CodingKeys: String, CodingKey {
        case id, title, isEnabled, shortcut, steps, text, trailingKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = container.contains(.title)
            ? try container.decode(String.self, forKey: .title)
            : nil
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        shortcut = try container.decode(ShortcutDefinition.self, forKey: .shortcut)
        if container.contains(.steps) {
            steps = try container.decode([MacroStep].self, forKey: .steps)
        } else {
            let text = try container.decode(String.self, forKey: .text)
            let trailing = try container.decodeIfPresent(TrailingKey.self, forKey: .trailingKey)
            steps = MacroStep.legacySteps(text: text, trailingKey: trailing)
        }
    }

    func definition(defaultTitle: String) -> MacroDefinition {
        MacroDefinition(
            id: id,
            title: title ?? defaultTitle,
            isEnabled: isEnabled,
            shortcut: shortcut,
            steps: steps
        )
    }
}

final class ApplicationSupportSettingsFile: SettingsFile {
    let parentDirectoryURL: URL
    let url: URL

    private let fileManager: FileManager

    convenience init(fileManager: FileManager = .default) {
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.init(applicationSupportDirectory: applicationSupportDirectory, fileManager: fileManager)
    }

    init(applicationSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        parentDirectoryURL = applicationSupportDirectory
            .appendingPathComponent("com.caost.Kocro", isDirectory: true)
        url = parentDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
    }

    var exists: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func read() throws -> Data {
        try Data(contentsOf: url)
    }

    func atomicReplace(with data: Data, permissions: Int16) throws {
        try fileManager.createDirectory(
            at: parentDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: parentDirectoryURL.path
        )

        let temporaryURL = parentDirectoryURL
            .appendingPathComponent(".settings-\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: temporaryURL.path
        )

        if exists {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else if Darwin.rename(temporaryURL.path, url.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }
}
