//
//  FulfillmentErrorMetadataTests.swift
//  PalaceTests
//
//  The download-failure report carries a `"book"` entry so a non-fatal can be
//  traced back to the title, distributor and acquisition type that failed.
//  That entry must be the book's loggable dictionary, not the unapplied
//  `loggableDictionary` method: a function value in `[String: Any]` metadata
//  compiles, and reaches Crashlytics as an opaque closure description.
//
//  Reachable here: `MyBooksDownloadCenter.reportDownloadFailure` (the body
//  `logBookDownloadFailure` forwards to), through the injected
//  `DeviceSpecificErrorMonitoring`; the test awaits the `Task` it returns. Not reachable: the three
//  `AdobeDRMHandler.handleFulfillmentResult` reports, which go to the static
//  `TPPErrorLogger`; those are covered by the verification grep only.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class FulfillmentErrorMetadataTests: XCTestCase {

    /// Records `logDownloadFailure` calls.
    private final class DownloadFailureMonitorSpy: DeviceSpecificErrorMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private var _metadata: [[String: Any]] = []
        private var _reasons: [String] = []

        var metadata: [[String: Any]] { lock.withLock { _metadata } }
        var reasons: [String] { lock.withLock { _reasons } }

        func logDownloadFailure(book: TPPBook, reason: String, error: Error?, metadata: [String: Any]) {
            lock.withLock {
                _metadata.append(metadata)
                _reasons.append(reason)
            }
        }

        func initialize() async {}
        func getDeviceID() -> String { "spy-device" }
        func isEnhancedLoggingEnabled() -> Bool { false }
        func logError(_ error: Error, context: String, metadata: [String: Any]) {}
        func logNetworkFailure(url: URL?, error: Error, context: String, metadata: [String: Any]) {}
        func getDeviceInfo() -> [String: String] { [:] }
    }

    private func makeBook(id: String, title: String, distributor: String) -> TPPBook {
        TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": title,
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z",
            "distributor": distributor
        ])!
    }

    private func makeCenter(monitor: DownloadFailureMonitorSpy) -> MyBooksDownloadCenter {
        MyBooksDownloadCenter(
            bookRegistry: TPPBookRegistryMock(),
            stateManager: DownloadStateManager(),
            reachability: MockReachability(initiallyConnected: true),
            deviceSpecificErrorMonitor: monitor
        )
    }

    func testLogBookDownloadFailure_ReportsBookDictionaryWithIdentifierAndTitle() async throws {
        let monitor = DownloadFailureMonitorSpy()
        let center = makeCenter(monitor: monitor)
        let book = makeBook(id: "urn:a2:book-dictionary", title: "Metadata Title", distributor: "Metadata Distributor")

        await center.reportDownloadFailure(
            book,
            reason: "Download Error",
            downloadTask: MockURLSessionDownloadTask(taskIdentifier: 7),
            metadata: nil
        ).value

        XCTAssertEqual(monitor.reasons, ["Download Error"])
        let bookEntry = try XCTUnwrap(
            monitor.metadata.first?["book"] as? [String: Any],
            "the \"book\" entry must be the book's loggable dictionary, not a function value"
        )
        XCTAssertEqual(bookEntry["bookID"] as? String, "urn:a2:book-dictionary")
        XCTAssertEqual(bookEntry["bookTitle"] as? String, "Metadata Title")
        XCTAssertEqual(bookEntry["bookDistributor"] as? String, "Metadata Distributor")
    }

    func testLogBookDownloadFailure_KeepsCallerMetadataAlongsideBookDictionary() async throws {
        let monitor = DownloadFailureMonitorSpy()
        let center = makeCenter(monitor: monitor)
        let book = makeBook(id: "urn:a2:caller-metadata", title: "Caller Metadata", distributor: "Caller Distributor")

        await center.reportDownloadFailure(
            book,
            reason: "Download Error",
            downloadTask: MockURLSessionDownloadTask(taskIdentifier: 8),
            metadata: ["mimeType": "application/problem+json"]
        ).value

        let reportedMetadata = try XCTUnwrap(monitor.metadata.first)
        XCTAssertEqual(reportedMetadata["mimeType"] as? String, "application/problem+json")
        let bookEntry = try XCTUnwrap(reportedMetadata["book"] as? [String: Any])
        XCTAssertEqual(bookEntry["bookID"] as? String, "urn:a2:caller-metadata")
    }
}
