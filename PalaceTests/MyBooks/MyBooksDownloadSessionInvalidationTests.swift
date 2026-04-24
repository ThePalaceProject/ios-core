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

final class MyBooksDownloadSessionInvalidationTests: XCTestCase {

    /// Contract 1: URLSession.downloadTask(with:) on an invalidated session must
    /// throw NSGenericException, not return a no-op task. If Apple ever changed
    /// this to return a cancelled task instead, the guard would become a no-op
    /// warning — harmless but dead code we'd want to know about.
    func testDownloadTask_onInvalidatedSession_throwsNSException() {
        let session = URLSession(configuration: .ephemeral)
        session.invalidateAndCancel()

        let request = URLRequest(url: URL(string: "https://example.test/book.epub")!)

        var caught: NSException?
        let block: @convention(block) () -> Void = {
            _ = session.downloadTask(with: request)
        }
        caught = TPPObjCExceptionCatcher.catchException(in: block)

        XCTAssertNotNil(caught, "invalidated session must throw when asked for a download task")
        XCTAssertEqual(caught?.name, .genericException,
                       "the specific exception class is load-bearing — the defensive guard is targeted at NSGenericException")
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
