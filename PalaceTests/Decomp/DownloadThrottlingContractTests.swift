//
//  DownloadThrottlingContractTests.swift
//  PalaceTests
//
//  PRE-WAVE test pack for the god-class decomposition campaign
//  (docs/architecture/god-class-decomposition-plan.md §3a-3 cluster
//  "Throttling + disk budget" + §5 "throttling … edge tests").
//
//  Pins the deterministic slice of `DownloadThrottlingService`'s concurrency
//  policy (Palace/MyBooks/DownloadThrottlingService.swift): setting the active
//  cap propagates to the shared `DownloadStateManager`, and EVERY re-application
//  of the cap ends by asking the delegate (MBDC) to re-pump the pending-download
//  queue. When this service moves into PalaceDownloads, the cap→pump coupling
//  must survive — a decomposition that dropped the trailing pump would leave
//  queued books stranded whenever a slot frees up.
//
//  SEAM (documented, not faked): the audiobook-preservation behavior
//  (`pauseAllDownloads` / over-cap `limitActiveDownloads` suspend NON-audiobook
//  tasks but never audiobook tasks) is NOT unit-pinned here. Observing it
//  requires spying `URLSessionTask.suspend()`, but `URLSessionDownloadTask`
//  cannot be meaningfully subclassed and a freshly-created task already reports
//  `.suspended`, so "suspended by policy" is indistinguishable from "never
//  started" at this seam. That branch is exercised on a sim (start N+1 mixed
//  ebook/audiobook downloads, background, observe the audiobook keeps streaming)
//  — noted for the extraction wave rather than pinned with a non-deterministic
//  assertion.
//

import XCTest
@testable import Palace

final class DownloadThrottlingContractTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var delegate: SpyThrottleDelegate!
    private var service: DownloadThrottlingService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        delegate = SpyThrottleDelegate()
        // Isolated NotificationCenter so the app-active observer can't fire from
        // unrelated suite activity.
        service = DownloadThrottlingService(
            stateManager: stateManager,
            notificationCenter: NotificationCenter()
        )
        service.delegate = delegate
    }

    override func tearDownWithError() throws {
        service = nil
        delegate = nil
        stateManager = nil
        try super.tearDownWithError()
    }

    /// `limitActiveDownloads(max:)` must (1) propagate the new cap to the shared
    /// state manager AND (2) re-pump the pending queue via the delegate. With no
    /// active downloads the suspend/resume body is a no-op, isolating exactly
    /// these two effects. Kills a mutant that dropped the `maxConcurrentDownloads`
    /// assignment and one that dropped the trailing `schedulePendingStartsAsync`.
    func test_limitActiveDownloads_propagatesCap_andRepumpsPendingQueue() async {
        service.limitActiveDownloads(max: 2)
        // The policy runs in a retained fire-and-forget Task; join it
        // deterministically instead of polling.
        await service.lastLimitActiveDownloadsTask?.value

        XCTAssertEqual(stateManager.maxConcurrentDownloads, 2,
                       "new cap must propagate to the shared state manager")
        XCTAssertEqual(delegate.pumpCount, 1,
                       "changing the cap must re-pump the pending-download queue exactly once")
    }

    /// `resumeIntelligentDownloads()` re-applies the CURRENT cap (giving
    /// previously-suspended tasks a chance to resume) and likewise re-pumps the
    /// queue — without changing the cap value. Kills a mutant that made resume a
    /// no-op (queued books would never restart after a throttle/foreground).
    func test_resumeIntelligentDownloads_reappliesCurrentCap_andRepumps() async {
        stateManager.maxConcurrentDownloads = 3

        service.resumeIntelligentDownloads()
        await service.lastLimitActiveDownloadsTask?.value

        XCTAssertEqual(stateManager.maxConcurrentDownloads, 3,
                       "resume must re-apply, not mutate, the current cap")
        XCTAssertEqual(delegate.pumpCount, 1,
                       "resume must re-pump the pending-download queue")
    }
}

// MARK: - Spy

/// Counts pending-queue re-pump requests. `schedulePendingStartsAsync` is a
/// `nonisolated async` protocol requirement, so the counter is NSLock-guarded
/// and read from the test thread after the joined policy Task completes.
private final class SpyThrottleDelegate: DownloadThrottlingServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _pumpCount = 0
    var pumpCount: Int { lock.withLock { _pumpCount } }

    func schedulePendingStartsAsync() async {
        lock.withLock { _pumpCount += 1 }
    }
}
