import Foundation

enum StoreError: Error {
    case invalidFile
    case io
}

protocol SettingsStoring {
    func load() throws -> AppSettings
    func save(_ value: AppSettings) throws
}

protocol SettingsFile {
    var exists: Bool { get }
    func read() throws -> Data
    func atomicReplace(with data: Data, permissions: Int16) throws
}
