//
//  AudiobookEngineMock.swift
//  PalaceTests
//
//  Protocol-shaped test double standing in for the vendor audiobook engines
//  Palace plumbs through at load time: Findaway (AudioEngine), Overdrive,
//  and LCP. The real engines are opaque SDKs (Findaway is closed-source,
//  Overdrive lives in an Apple-Silicon-only XCFramework, LCP is a Readium
//  module) — none expose mock-friendly entry points. This file gives the
//  test target a single seam to drive load/open/release semantics
//  without dragging the vendor stacks into a unit test.
//
//  Shape mirrors Palace's existing mock pattern (TPPDRMAuthorizingMock,
//  TPPMyBooksDownloadsCenterMock): subclassable, observable counters +
//  captured args, and a `removeAll()` reset hook for tearDown. The class
//  is intentionally `class` (not `final`) so individual test files can
//  subclass to add scenario-specific behaviour without re-implementing
//  the bookkeeping.
//
//  WHY THIS EXISTS (forward-pointing seam):
//  Three Crashlytics signatures persist in 3.0.0 with effectively zero
//  unit-test coverage on the engine side of the audiobook stack:
//    F-001 Adobe RMSDK background watchdog          (47 users / 156 events)
//    F-003 FAEChapterStatus _cacheForChapterDescription EXC_BREAKPOINT
//    F-004 AudiobookLoader.finalizeBuild EXC_BREAKPOINT
//
//  The fix for any of these will eventually require a protocol-shaped seam
//  in Palace/Audiobooks/ so test doubles can verify the open/release/
//  background-shutdown contracts. This mock is the consumer-side of that
//  future seam: when AudiobookLoader / AudioBookVendorsHelper / the
//  Findaway lifecycle wrapper gain protocol surfaces, swap an
//  `AudiobookEngineMock` in via the existing dependency-injection seam
//  in AudiobookLoader.load() (already takes a `DRMDecryptor?`, just needs
//  one more knob for the engine handle).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Pure-Swift Findaway/Overdrive/LCP engine stand-in. No live SDK calls.
///
/// Tests use this to drive deterministic open/release/repeat-open patterns —
/// the same patterns that, on real devices, produce the F-003 semaphore
/// dispose race and the F-001 background-watchdog crash.
class AudiobookEngineMock {

    // MARK: - Configurable Test Properties

    /// Set non-nil to make `openBook` return this error.
    var openBookErrorToReturn: NSError?

    /// Number of chapters the mock advertises after a successful open.
    /// Default 0 (empty book) — exercises F-003 empty-chapter caching
    /// guard. Tests for the populated path bump this to N.
    var chapterCount: Int = 0

    /// Set true to model an engine that no-ops `closeBook` (i.e. semaphore
    /// never signals). Used to test repeated-open guards against the
    /// "engine still finishing close" window.
    var deferCloseCompletion: Bool = false

    // MARK: - Tracking (observable)

    private(set) var openBookCallCount: Int = 0
    private(set) var closeBookCallCount: Int = 0
    private(set) var releaseResourcesCallCount: Int = 0
    private(set) var didEnterBackgroundCallCount: Int = 0
    private(set) var willTerminateCallCount: Int = 0

    /// FIFO log of (bookId, license) pairs captured at openBook entry.
    /// Tests assert on this to detect mis-routed open calls.
    private(set) var openedBooks: [(bookId: String, license: String?)] = []

    /// True between the most recent successful `openBook` and its matched
    /// `closeBook`. Used to verify rapid-open contracts don't double-open
    /// or double-release.
    private(set) var isBookOpen: Bool = false

    /// Pending close completion when `deferCloseCompletion` is true.
    private var pendingCloseCompletion: (() -> Void)?

    // MARK: - Engine surface (mock implementation)

    /// Stand-in for `FAEAudioEngine.shared().play(forAudiobookID:license:)`
    /// or the equivalent Overdrive entry point. Synchronous like the real
    /// SDKs (the engine is responsible for its own internal threading).
    @discardableResult
    func openBook(bookId: String, license: String?) -> NSError? {
        openBookCallCount += 1
        openedBooks.append((bookId: bookId, license: license))
        if let err = openBookErrorToReturn {
            return err
        }
        isBookOpen = true
        return nil
    }

    /// Stand-in for the engine's close/release call. The real SDK signals
    /// an internal semaphore inside this call — repeat opens of the same
    /// book before the semaphore drains produce the F-003 EXC_BREAKPOINT.
    func closeBook(bookId: String, completion: @escaping () -> Void) {
        closeBookCallCount += 1
        if deferCloseCompletion {
            // Stash the completion. Test code calls `flushPendingClose()`
            // to model the engine eventually signalling.
            pendingCloseCompletion = { [weak self] in
                self?.isBookOpen = false
                completion()
            }
        } else {
            isBookOpen = false
            completion()
        }
    }

    /// Mirrors LCPAudiobooks.releaseResources — the LCP-side decryptor
    /// drop that AudiobookSessionManager.stopPlayback() invokes before
    /// niling the manager.
    func releaseResources() {
        releaseResourcesCallCount += 1
    }

    /// Mirrors `FindawayAudiobookLifecycleListener.didEnterBackground()`.
    /// On the real SDK this triggers RMSDK static dtors that can blow
    /// past the iOS watchdog budget (F-001).
    func didEnterBackground() {
        didEnterBackgroundCallCount += 1
    }

    /// Mirrors `willTerminate()` lifecycle hook.
    func willTerminate() {
        willTerminateCallCount += 1
    }

    /// Fires the deferred close completion stashed when
    /// `deferCloseCompletion=true`. No-op if nothing is pending.
    func flushPendingClose() {
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        completion?()
    }

    // MARK: - Reset

    /// Wipe all captured state. Call in tearDown so tests are independent.
    /// Mirrors the `removeAll()` pattern used by TPPUserAccountMock and
    /// TPPMyBooksDownloadsCenterMock.
    func removeAll() {
        openBookErrorToReturn = nil
        chapterCount = 0
        deferCloseCompletion = false
        openBookCallCount = 0
        closeBookCallCount = 0
        releaseResourcesCallCount = 0
        didEnterBackgroundCallCount = 0
        willTerminateCallCount = 0
        openedBooks.removeAll()
        isBookOpen = false
        pendingCloseCompletion = nil
    }
}
