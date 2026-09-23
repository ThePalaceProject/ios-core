//
//  MyBooksDownloadSessionInvalidationTests.swift
//  PalaceTests
//
//  Regression coverage for MyBooksDownloadCenter.addDownloadTask's defensive
//  NSException guard. A flake in the test suite — `NSGenericException: Task
//  created in a session that has been invalidated` — surfaced when a detached
//  start-download Task fired after the download session had been invalidated
//  (by app lifecycle, or by a previous test's teardown). The production code
//  now catches that exception via TPPObjCExceptionCatcher; these tests lock in
//  the two contracts the fix depends on.
//

import XCTest
@testable import Palace

@MainActor
final class MyBooksDownloadSessionInvalidationTests: XCTestCase {

    /// Contract 1: `URLSession.downloadTask(with:)` on an invalidated session
    /// historically threw `NSGenericException` ("Task created in a session that
    /// has been invalidated"). The production guard in
    /// `MyBooksDownloadCenter.addDownloadTask` wraps the call in
    /// `TPPObjCExceptionCatcher` to recover from that.
    ///
    /// On iOS 26.2 (CI's runtime, full-suite) we observed a quieter behavior:
    /// the call returns without throwing. The test now accepts EITHER the
    /// historical throw OR a quiet return — what we actually need to assert is
    /// that the production code can call `session.downloadTask(with:)` on an
    /// invalidated session WITHOUT crashing the process. If Apple has quietly
    /// stopped throwing, the catcher becomes a no-op (dead code) but the
    /// production behavior is still correct — that's a tracking observation,
    /// not a bug.
    func testDownloadTask_onInvalidatedSession_isSafelyCatchable() {
        let session = URLSession(configuration: .ephemeral)
        session.invalidateAndCancel()

        let request = URLRequest(url: URL(string: "https://example.test/book.epub")!)

        var caught: NSException?
        var returnedTask: URLSessionDownloadTask?
        let block: @convention(block) () -> Void = {
            returnedTask = session.downloadTask(with: request)
        }
        caught = TPPObjCExceptionCatcher.catchException(in: block)

        if let caught = caught {
            // Historical behavior (iOS ≤ 18.4): NSGenericException raised.
            // The production guard catches it; this test pins that contract.
            XCTAssertEqual(caught.name, .genericException,
                           "Historical behavior: invalidated-session downloadTask raises NSGenericException")
        } else {
            // Apple-changed behavior (observed iOS 26.2): no exception. The
            // call must at least return a task object (possibly already
            // cancelled) — it cannot be a black hole that fires no callback,
            // because the production code's `guard let task` would then never
            // resolve and the download would silently never start.
            XCTAssertNotNil(returnedTask,
                            "If Apple stopped throwing on invalidated sessions, downloadTask must still return a task object — production code's `guard let task` depends on that")
        }
    }

    /// Contract 2: TPPObjCExceptionCatcher.catchException actually returns the
    /// NSException instead of letting it propagate. This is what keeps the
    /// production code from crashing the whole process.
    func testExceptionCatcher_returnsNSException_insteadOfPropagating() {
        var caught: NSException?
        let block: @convention(block) () -> Void = {
            NSException(name: .genericException, reason: "synthetic", userInfo: nil).raise()
        }
        caught = TPPObjCExceptionCatcher.catchException(in: block)

        XCTAssertNotNil(caught)
        XCTAssertEqual(caught?.name, .genericException)
        XCTAssertEqual(caught?.reason, "synthetic")
    }

    /// Contract 3: on a live session, the call returns a real task — the guard
    /// must not accidentally no-op the happy path.
    func testDownloadTask_onLiveSession_returnsTaskWithoutException() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let request = URLRequest(url: URL(string: "https://example.test/book.epub")!)

        var task: URLSessionDownloadTask?
        let block: @convention(block) () -> Void = {
            task = session.downloadTask(with: request)
        }
        let caught = TPPObjCExceptionCatcher.catchException(in: block)

        XCTAssertNil(caught)
        XCTAssertNotNil(task)
    }
}
