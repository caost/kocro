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
            let decoded = try JSONDecoder().decode(AppSettings.self, from: file.read())
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
