import Foundation
import OSLog

struct LatencyReport: Codable, Equatable {
    let samples: [Double]
    let p50: Double
    let p95: Double
}

enum LatencyError: Error, Equatable {
    case sampleCount
}

enum PostingLatencyRecorder {
    static let requiredSampleCount = 100

    static func report(_ values: [Double]) throws -> LatencyReport {
        guard values.count == requiredSampleCount else {
            throw LatencyError.sampleCount
        }
        let sorted = values.sorted()
        return LatencyReport(
            samples: values,
            p50: sorted[49],
            p95: sorted[94]
        )
    }
}

protocol PostingMeasurementRecording: AnyObject {
    func record(
        receivedAt: ContinuousClock.Instant,
        postedAt: ContinuousClock.Instant
    ) throws
}

protocol LatencyReportStoring: AnyObject {
    func prepareReport(at url: URL) throws
    func persist(_ report: LatencyReport, at url: URL) throws
}

final class FileLatencyReportStorage: LatencyReportStoring {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareReport(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try secureDirectory(at: directory)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func persist(_ report: LatencyReport, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try secureDirectory(at: directory)
        let data = try JSONEncoder().encode(report)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func secureDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}

final class MeasurementSession: PostingMeasurementRecording, @unchecked Sendable {
    static let argument = "--measure-posting-latency"

    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(argument)
    }

    private let enabled: Bool
    private let reportURL: URL
    private let storage: LatencyReportStoring
    private let preparationError: Error?
    private let lock = NSLock()
    private var recordedSamples: [Double] = []
    private var progressHandler: ((Int) -> Void)?
    private var reportScheduled = false

    init(
        enabled: Bool = MeasurementSession.isRequested(),
        reportURL: URL? = nil,
        fileManager: FileManager = .default,
        storage: LatencyReportStoring? = nil
    ) {
        self.enabled = enabled
        self.reportURL = reportURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.caost.Kocro", isDirectory: true)
            .appendingPathComponent("posting-latency.json")
        let reportStorage = storage ?? FileLatencyReportStorage(fileManager: fileManager)
        self.storage = reportStorage
        if enabled {
            do {
                try reportStorage.prepareReport(at: self.reportURL)
                preparationError = nil
            } catch {
                preparationError = error
            }
        } else {
            preparationError = nil
        }
    }

    var sampleCount: Int {
        locked { recordedSamples.count }
    }

    var onProgress: ((Int) -> Void)? {
        get { locked { progressHandler } }
        set { locked { progressHandler = newValue } }
    }

    func record(
        receivedAt: ContinuousClock.Instant,
        postedAt: ContinuousClock.Instant
    ) throws {
        let update: (count: Int, handler: ((Int) -> Void)?, report: LatencyReport?)? = try locked {
            guard enabled else { return nil }
            if let preparationError { throw preparationError }
            guard recordedSamples.count < PostingLatencyRecorder.requiredSampleCount else {
                return nil
            }

            let components = receivedAt.duration(to: postedAt).components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1e15
            recordedSamples.append(milliseconds)

            let report: LatencyReport?
            if recordedSamples.count == PostingLatencyRecorder.requiredSampleCount,
               !reportScheduled {
                reportScheduled = true
                report = try PostingLatencyRecorder.report(recordedSamples)
            } else {
                report = nil
            }
            return (recordedSamples.count, progressHandler, report)
        }

        guard let update else { return }
        update.handler?(update.count)
        if let report = update.report {
            try storage.persist(report, at: reportURL)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum PostingMeasurementLog {
    private static let logger = Logger(
        subsystem: "com.caost.Kocro",
        category: "PostingMeasurement"
    )

    static func record(_ error: Error) {
        let errorType = String(reflecting: type(of: error))
        logger.error("Posting latency measurement failed: \(errorType, privacy: .public)")
    }
}
