//
//  ReaderServiceOpenFailureRecoveryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
#if LCP
import ReadiumLCP
#endif

/// Records what the failure handler did. Main-actor isolated so the
/// service's `@MainActor` closures can capture it.
@MainActor
private final class OpenFailureSpy {
    var connected = true
    var alerts: [(title: String, message: String?)] = []
    var redownloads: [String] = []
}

/// PP-5431 — what a failed book open does next. The first failure deletes the
/// local copy and re-downloads it, which needs the network; offline it must
/// leave the copy and its state alone and say a connection is needed.
@MainActor
final class ReaderServiceOpenFailureRecoveryTests: XCTestCase {

    private var spy: OpenFailureSpy!
    private var service: ReaderService!
    private let book = TPPBookMocker.snapshotEPUB()
    private let openError = LibraryServiceError.openFailed(
        NSError(domain: "Adobe DRM decoding error", code: 1001)
    )

    override func setUp() {
        super.setUp()
        let spy = OpenFailureSpy()
        self.spy = spy
        service = ReaderService(
            rootViewController: { nil },
            isConnected: { spy.connected },
            presentAlert: { title, message in spy.alerts.append((title, message)) },
            redownloadAndReopen: { book, _ in spy.redownloads.append(book.identifier) },
            imageCache: { MockImageCache() }
        )
    }

    override func tearDown() {
        service = nil
        spy = nil
        super.tearDown()
    }

    // MARK: - Decision table

    /// Every (retry, definitive license error, connected) cell, so a change to
    /// one branch cannot move another without a failing cell.
    func testOpenFailureRecovery_EveryCombination() {
        typealias R = ReaderService.OpenFailureRecovery
        let cases: [(isRetry: Bool, definitive: Bool, connected: Bool, expected: R)] = [
            (false, false, true, .redownload),
            (false, false, false, .requireConnection),
            (false, true, true, .showError),
            (false, true, false, .showError),
            (true, false, true, .showError),
            (true, false, false, .showError),
            (true, true, true, .showError),
            (true, true, false, .showError),
        ]
        for c in cases {
            XCTAssertEqual(
                ReaderService.openFailureRecovery(
                    isRetry: c.isRetry,
                    isDefinitiveLicenseError: c.definitive,
                    isConnected: c.connected
                ),
                c.expected,
                "isRetry=\(c.isRetry) definitive=\(c.definitive) connected=\(c.connected)"
            )
        }
    }

    // MARK: - The failure handler

    /// Offline on the first failure: no delete-and-re-download, and the patron
    /// is told to reconnect instead of seeing a Content Protection Error.
    func testFirstOpenFailure_WhenOffline_AsksForConnectionAndDoesNotRedownload() {
        spy.connected = false

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)

        XCTAssertTrue(spy.redownloads.isEmpty, "Offline must not delete the local copy and start a download")
        XCTAssertEqual(spy.alerts.map(\.title), [Strings.MyDownloadCenter.noConnectionTitle])
        XCTAssertEqual(spy.alerts.first?.message, Strings.MyDownloadCenter.noConnectionMessage)
    }

    /// Online on the first failure: the transparent re-download runs and no
    /// alert is shown yet.
    func testFirstOpenFailure_WhenOnline_RedownloadsWithoutAlert() {
        spy.connected = true

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)

        XCTAssertEqual(spy.redownloads, [book.identifier])
        XCTAssertTrue(spy.alerts.isEmpty)
    }

    /// A failure after the re-download is final: the Content Protection Error is
    /// shown and no second download starts.
    func testRetryOpenFailure_ShowsContentProtectionErrorWithoutRedownload() {
        spy.connected = true

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: true)

        XCTAssertTrue(spy.redownloads.isEmpty)
        XCTAssertEqual(spy.alerts.map(\.title), ["Content Protection Error"])
    }

    #if LCP
    /// An expired, returned or revoked LCP license cannot be fixed by
    /// downloading again, so it shows the Content Protection Error even
    /// offline, and nothing is re-downloaded.
    func testDefinitiveLicenseError_WhenOffline_ShowsContentProtectionError() {
        spy.connected = false
        let expired = LibraryServiceError.openFailed(
            LCPError.licenseStatus(.expired(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1)))
        )

        service.presentOpenFailureAlert(for: expired, book: book, isRetry: false)

        XCTAssertTrue(spy.redownloads.isEmpty)
        XCTAssertEqual(spy.alerts.map(\.title), ["Content Protection Error"])
    }
    #endif
}
