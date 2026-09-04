import Foundation
import XCTest
@testable import Kocro

final class PostingLatencyRecorderTests: XCTestCase {
    func testNearestRankUsesExactlyOneHundredSamples() throws {
        let report = try PostingLatencyRecorder.report(
            (1...100).reversed().map(Double.init)
        )

        XCTAssertEqual(report.p50, 50)
        XCTAssertEqual(report.p95, 95)
        XCTAssertEqual(report.samples.count, 100)
    }

    func testReportRejectsAnyCountOtherThanOneHundred() {
        XCTAssertThrowsError(try PostingLatencyRecorder.report([1, 2])) { error in
            XCTAssertEqual(error as? LatencyError, .sampleCount)
        }
    }

    func testMeasurementSessionPersistsOnlyFirstOneHundredConcurrentSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root
            .appendingPathComponent("com.caost.Kocro", isDirectory: true)
            .appendingPathComponent("posting-latency.json")
        let session = MeasurementSession(enabled: true, reportURL: reportURL)
        let progressLock = NSLock()
        var progress: [Int] = []
        session.onProgress = { count in
            progressLock.lock()
            progress.append(count)
            progressLock.unlock()
        }
        let start = ContinuousClock.now

        DispatchQueue.concurrentPerform(iterations: 120) { index in
            try? session.record(
                receivedAt: start,
                postedAt: start.advanced(by: .milliseconds(index + 1))
            )
        }

        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(LatencyReport.self, from: data)
        XCTAssertEqual(session.sampleCount, 100)
        XCTAssertEqual(report.samples.count, 100)
        progressLock.lock()
        let recordedProgress = progress
        progressLock.unlock()
        XCTAssertEqual(recordedProgress.sorted(), Array(1...100))

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: reportURL.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: reportURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEnabledSessionInvalidatesExistingValidReportBeforeRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let reportURL = root.appendingPathComponent("posting-latency.json")
        let oldReport = try PostingLatencyRecorder.report(
            (1...100).map(Double.init)
        )
        try JSONEncoder().encode(oldReport).write(to: reportURL, options: .atomic)

        _ = MeasurementSession(enabled: true, reportURL: reportURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
    }

    func testDisabledMeasurementPreservesExistingReportAndDoesNotRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let reportURL = root.appendingPathComponent("posting-latency.json")
        let existing = Data("existing report".utf8)
        try existing.write(to: reportURL)
        let session = MeasurementSession(enabled: false, reportURL: reportURL)

        try session.record(receivedAt: .now, postedAt: .now)

        XCTAssertEqual(session.sampleCount, 0)
        XCTAssertEqual(try Data(contentsOf: reportURL), existing)
    }

    func testPreparationFailureMakesRecordThrowWithoutAcceptingSamplesOrWritingReport() {
        let storage = LatencyReportStorageSpy()
        storage.invalidationError = MeasurementTestError.write
        let session = MeasurementSession(
            enabled: true,
            reportURL: URL(fileURLWithPath: "/measurement/posting-latency.json"),
            storage: storage
        )

        XCTAssertThrowsError(
            try session.record(receivedAt: .now, postedAt: .now)
        ) { error in
            XCTAssertEqual(error as? MeasurementTestError, .write)
        }
        XCTAssertEqual(session.sampleCount, 0)
        XCTAssertEqual(storage.prepareCount, 1)
        XCTAssertEqual(storage.persistCount, 0)
    }

    func testMeasurementRunsAfterFinalPostAndFailureDoesNotChangePostingResult() throws {
        let api = EventAPISpy()
        let measurement = ThrowingMeasurementRecorder()
        var loggedErrorTypes: [String] = []
        measurement.onRecord = {
            XCTAssertEqual(api.posted, api.created)
        }
        let poster = EventBatchPoster(
            api: api,
            maximumUTF16Units: 4,
            measurement: measurement,
            measurementFailure: { error in
                loggedErrorTypes.append(String(reflecting: type(of: error)))
            }
        )
        let request = ExecutionRequest(
            id: UUID(),
            shortcut: "F13",
            text: "abcdef",
            trailing: .enter,
            receivedAt: .now
        )

        XCTAssertNoThrow(try poster.buildAndPost(request))
        XCTAssertEqual(api.posted, api.created)
        XCTAssertEqual(loggedErrorTypes, [String(reflecting: MeasurementTestError.self)])
    }
}

private enum MeasurementTestError: Error, Equatable {
    case write
}

private final class LatencyReportStorageSpy: LatencyReportStoring {
    var invalidationError: Error?
    private(set) var prepareCount = 0
    private(set) var persistCount = 0

    func prepareReport(at url: URL) throws {
        prepareCount += 1
        if let invalidationError { throw invalidationError }
    }

    func persist(_ report: LatencyReport, at url: URL) throws {
        persistCount += 1
    }
}

private final class ThrowingMeasurementRecorder: PostingMeasurementRecording {
    var onRecord: (() -> Void)?

    func record(
        receivedAt: ContinuousClock.Instant,
        postedAt: ContinuousClock.Instant
    ) throws {
        onRecord?()
        throw MeasurementTestError.write
    }
}
