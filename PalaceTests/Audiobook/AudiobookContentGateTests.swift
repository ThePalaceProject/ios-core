//
//  AudiobookContentGateTests.swift
//  PalaceTests
//
//  Regression coverage for 323-Cause-1: the LCP-audiobook cold-open dead-end.
//
//  The bug: an LCP audiobook flips to `.downloadSuccessful` the instant its
//  tiny `.lcpl` license lands, but the real `.lcpa` content downloads
//  SEPARATELY and can permanently fail to arrive. The old pre-open gate only
//  POLLED for the content file (`awaitAudiobookContentLocal` — "a wait, not a
//  trigger"). With no download in flight, that poll spun the full 180s window
//  then surfaced "Audiobook Unavailable" — forever. This was the #1-volume
//  patron complaint ("spins then unavailable").
//
//  The fix: `gateOnLCPContentDownload` now TRIGGERS the content download (via
//  the idempotent `redownloadLCPContentFile` self-heal seam) BEFORE awaiting,
//  so the `.lcpa` actually lands. The "Audiobook Unavailable" dead-end is only
//  reachable AFTER a real trigger + a genuine timeout.
//
//  These tests pin (1) the pure gate predicate, (2) that the gate TRIGGERS the
//  download when content is missing rather than only polling, (3) that the
//  unavailable outcome is never reached without a trigger, and (4) the ordered
//  trigger → await contract via a snapshot.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookContentGateTests: XCTestCase {

    private var appContainer: AppContainer!
    private var triggeredBookIds: [String] = []
    private var sut: AudiobookSessionManager!
    /// Streaming-ON managers built by `makeStreamingSUT`, torn down with `sut`
    /// so a live session cannot outlive its test and bleed into the next one.
    private var streamingSUTs: [AudiobookSessionManager] = []

    override func setUp() async throws {
        try await super.setUp()
        triggeredBookIds = []
        streamingSUTs = []
        appContainer = makeTestAppContainer()
        // Spy trigger: records every book the gate asks to (re)download, so a
        // test can prove the gate TRIGGERS rather than only polls. The flag is
        // pinned OFF here (download-first); streaming-ON cases use
        // `makeStreamingSUT()`.
        sut = AudiobookSessionManager(
            appContainer: appContainer,
            lcpContentDownloadTrigger: { [weak self] book in
                self?.triggeredBookIds.append(book.identifier)
            },
            lcpStreamingEnabledProvider: { false }
        )
    }

    override func tearDown() async throws {
        await sut?.stopPlayback(dismissPhoneUI: false)
        for manager in streamingSUTs {
            await manager.stopPlayback(dismissPhoneUI: false)
        }
        streamingSUTs = []
        appContainer?.settings.downloadOnlyOnWiFi = false
        sut = nil
        appContainer = nil
        triggeredBookIds = []
        try await super.tearDown()
    }

    // MARK: - Pure predicate (mutation-focused)

    // Flag OFF (`streamingEnabled: false`) — the download-first gate, unchanged.
    func testShouldTrigger_lcpBookContentMissingNotRecovery_returnsTrue() {
        XCTAssertTrue(
            AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(
                isColdLoadRecovery: false, canOpenLCPBook: true, contentIsLocal: false, streamingEnabled: false),
            "A first cold open of an LCP audiobook whose .lcpa isn't on disk must trigger a content download — this is the exact 323-Cause-1 dead-end")
    }

    func testShouldTrigger_contentAlreadyLocal_returnsFalse() {
        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(
                isColdLoadRecovery: false, canOpenLCPBook: true, contentIsLocal: true, streamingEnabled: false),
            "When the .lcpa is already on disk there is nothing to download — open immediately")
    }

    func testShouldTrigger_coldLoadRecovery_returnsFalse() {
        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(
                isColdLoadRecovery: true, canOpenLCPBook: true, contentIsLocal: false, streamingEnabled: false),
            "Cold-load recovery re-opens skip the gate — content is already local by then, and re-gating would double the wait")
    }

    func testShouldTrigger_notLCPBook_returnsFalse() {
        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(
                isColdLoadRecovery: false, canOpenLCPBook: false, contentIsLocal: false, streamingEnabled: false),
            "The content gate is LCP-specific — a non-LCP audiobook must not be routed through the LCP re-download seam")
    }

    // PP-4957 — Flag ON (`streamingEnabled: true`) short-circuits the gate to
    // false, so an LCP audiobook opens (and streams) without a content download.
    func testShouldTrigger_streamingEnabled_overridesDownloadFirst_returnsFalse() {
        // Same inputs as `testShouldTrigger_lcpBookContentMissingNotRecovery_returnsTrue`
        // (which returns TRUE with the flag off) — the ONLY difference is the flag,
        // so this pins the `if streamingEnabled { return false }` branch: deleting
        // it makes this assertion fail.
        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(
                isColdLoadRecovery: false, canOpenLCPBook: true, contentIsLocal: false, streamingEnabled: true),
            "With streaming enabled, an LCP audiobook is playable on its license alone — the gate must NOT force a content download before opening")
    }

    func testShouldTrigger_streamingEnabled_neverBlocks_acrossInputs() {
        // Streaming ON dominates every other input — no combination makes the
        // open WAIT for the archive. Read this alongside
        // `testShouldFetch_isIndependentOfStreaming_acrossInputs`: this predicate
        // answers "must the patron wait?", that one answers "must the audio be
        // fetched?". PP-4957 had only this predicate, so answering "no wait"
        // silently also answered "no fetch" — which is PP-5135.
        for cold in [true, false] {
            for canOpen in [true, false] {
                for local in [true, false] {
                    XCTAssertFalse(
                        AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(
                            isColdLoadRecovery: cold, canOpenLCPBook: canOpen, contentIsLocal: local, streamingEnabled: true),
                        "streamingEnabled must force false regardless of (cold: \(cold), canOpen: \(canOpen), local: \(local))")
                }
            }
        }
    }

    // MARK: - PP-5135: fetching the archive is a SEPARATE question from waiting on it

    /// The fetch predicate must not consult the streaming flag at all. Whether
    /// the audio belongs on the device is not a function of how fast playback can
    /// start. Driven over the full input cube so a re-introduced
    /// `if streamingEnabled { return false }` fails here immediately.
    func testShouldFetch_isIndependentOfStreaming_acrossInputs() {
        for cold in [true, false] {
            for canOpen in [true, false] {
                for local in [true, false] {
                    let expected = !cold && canOpen && !local
                    XCTAssertEqual(
                        AudiobookSessionManager.shouldFetchContentBeforeOpen(
                            isColdLoadRecovery: cold, canOpenLCPBook: canOpen, contentIsLocal: local),
                        expected,
                        "fetch decision must be (!cold && canOpen && !local) for (cold: \(cold), canOpen: \(canOpen), local: \(local))")
                }
            }
        }
    }

    /// PP-5135, the regression this fix exists for.
    ///
    /// Streaming ON + an LCP audiobook whose `.lcpa` is not on disk. Before the
    /// fix the gate returned `.proceed` and did nothing else, so the archive was
    /// never requested by anyone — the book stayed license-only for the life of
    /// the loan while the shelf said Downloaded, and the first offline open
    /// dead-ended in `PublicationOpenError`. Measured on device: every borrowed
    /// LCP audiobook had a 2–3 KB `.lcpl` and no `.lcpa` at all.
    ///
    /// The contract is BOTH halves at once, which is why they are asserted
    /// together: the archive is requested, and the patron is not made to wait for
    /// it. Asserting only the trigger would pass for a gate that blocks; asserting
    /// only `.proceed` is exactly the assertion that let the defect ship.
    func testGate_streamingEnabled_contentMissing_fetchesInBackgroundWithoutBlocking() async {
        let streamingSut = makeStreamingSUT()
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        var didAwait = false

        let result = await streamingSut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { _ in
                didAwait = true
                return true
            }
        )

        XCTAssertEqual(triggeredBookIds, [book.identifier],
            "streaming ON must still REQUEST the .lcpa, or the book can never be played offline (PP-5135)")
        XCTAssertFalse(didAwait,
            "streaming ON must NOT wait for the archive — blocking here re-imposes the multi-gigabyte wait streaming exists to remove")
        XCTAssertEqual(result, .proceed,
            "the open proceeds immediately and streams while the archive lands behind it")
    }

    /// Guard on the other side: streaming ON but the content is ALREADY on disk.
    /// Nothing to fetch, so triggering would start a redundant transfer of an
    /// archive the device already holds.
    func testGate_streamingEnabled_contentAlreadyLocal_doesNotFetch() async {
        let streamingSut = makeStreamingSUT()
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await streamingSut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: true,
            awaitContentLanding: { _ in true }
        )

        XCTAssertTrue(triggeredBookIds.isEmpty,
            "the archive is already on disk — re-fetching it would burn the patron's bandwidth for nothing")
        XCTAssertEqual(result, .proceed)
    }

    /// Streaming ON on a cold-load recovery re-open. The recovery path only runs
    /// once the content is already local, so a fetch here would be redundant —
    /// and this pins the `isColdLoadRecovery` clause of the new predicate at the
    /// GATE, which the pure-predicate cube above cannot attribute to the gate.
    func testGate_streamingEnabled_coldLoadRecovery_doesNotFetch() async {
        let streamingSut = makeStreamingSUT()
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await streamingSut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: true,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { _ in true }
        )

        XCTAssertTrue(triggeredBookIds.isEmpty,
            "a cold-load recovery re-open already has its content — it must not start a transfer")
        XCTAssertEqual(result, .proceed)
    }

    /// PP-5135, Claim E at THIS site: the open gate must not start a background
    /// archive fetch against the patron's `downloadOnlyOnWiFi` preference.
    ///
    /// Review found this hole twice, mirrored. The DownloadCentre trigger had a
    /// surviving mutant on its wifi guard; fixing that left the SAME gap here —
    /// every other test in this suite sets `downloadOnlyOnWiFi = false`, so
    /// mutating `downloadOnlyOnWiFi: settings.downloadOnlyOnWiFi` to `false` in
    /// `AudiobookSessionManager` survived the whole suite. Claim E says "neither
    /// trigger site"; without this it was verified at one and asserted at the
    /// other.
    ///
    /// `isOnWiFi` is not driveable (`public`, not `open`, so `MockReachability`
    /// cannot stub it) and reads a deterministically-`.unsatisfied`
    /// `NWPathMonitor` — which is precisely what makes the preference the
    /// deciding input here, the same way it does in the DownloadCentre twin.
    func testGate_streamingEnabled_wifiOnlyPreferenceSet_doesNotFetchButStillProceeds() async {
        appContainer.settings.downloadOnlyOnWiFi = true
        let manager = AudiobookSessionManager(
            appContainer: appContainer,
            reachabilityProvider: { MockReachability(initiallyConnected: true) },
            lcpContentDownloadTrigger: { [weak self] book in
                self?.triggeredBookIds.append(book.identifier)
            },
            lcpStreamingEnabledProvider: { true }
        )
        streamingSUTs.append(manager)
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await manager.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { _ in true }
        )

        XCTAssertTrue(triggeredBookIds.isEmpty,
            "download-only-on-WiFi is a preference the patron set — opening a book must not pull a multi-hundred-megabyte archive against it (PP-5135, Claim E)")
        XCTAssertEqual(result, .proceed,
            "the open still proceeds and streams; only the background fetch is deferred")
    }

    /// Streaming-ON manager sharing the suite's spy trigger. The flag is injected
    /// rather than read from `RemoteFeatureFlags.shared`, which is a live remote
    /// value and therefore non-deterministic in the test host.
    private func makeStreamingSUT() -> AudiobookSessionManager {
        // The WiFi-only preference is pinned because PP-5135's background fetch
        // is gated on it, and reading it from the test host would make these
        // assertions depend on whatever UserDefaults a previous test left behind.
        //
        // Reachability is injected for connectivity ONLY. `MockReachability`
        // overrides `isConnectedToNetwork()` but CANNOT override `isOnWiFi` —
        // that is `public`, not `open`, across the PalaceNetwork module boundary,
        // so it still reads an unstarted `NWPathMonitor.currentPath` and answers
        // false. These cases are therefore "connected, not on wifi", which is
        // what makes `downloadOnlyOnWiFi` the deciding input in both directions.
        // The full truth table for the rule itself is driven directly in
        // `LocalBookContentServiceTests.testBackgroundFetchAllowed_*`, where it
        // is a pure function and needs no doubles.
        appContainer.settings.downloadOnlyOnWiFi = false
        let manager = AudiobookSessionManager(
            appContainer: appContainer,
            reachabilityProvider: { MockReachability(initiallyConnected: true) },
            lcpContentDownloadTrigger: { [weak self] book in
                self?.triggeredBookIds.append(book.identifier)
            },
            lcpStreamingEnabledProvider: { true }
        )
        streamingSUTs.append(manager)
        return manager
    }

    /// PP-5135: the fetch must NOT start when the background-fetch policy refuses
    /// — the book still opens and streams, only the archive is deferred.
    ///
    /// Honest about what it drives. `Reachability.isOnWiFi` is `public`, not
    /// `open`, across the PalaceNetwork module boundary, so `MockReachability`
    /// CANNOT stub it; it falls through to an unstarted `NWPathMonitor` and
    /// answers false. An earlier version of this test set `downloadOnlyOnWiFi`
    /// and claimed to be testing "cellular", while actually depending on that
    /// un-stubbable false — the assertion would have passed for the wrong reason,
    /// and would keep passing if the wifi clause were deleted from the gate.
    ///
    /// So this drives the input the suite CAN control: connectivity. Offline is a
    /// refusal the policy makes for its own reason, and it pins that the gate
    /// consults the policy at all. The cellular-plus-preference cell is pinned
    /// directly, and without doubles, in
    /// `LocalBookContentServiceTests.testBackgroundFetchAllowed_onCellularWithWiFiOnlySet_refuses`,
    /// where the rule is a pure function.
    func testGate_streamingEnabled_whenPolicyRefuses_doesNotFetchButStillProceeds() async {
        appContainer.settings.downloadOnlyOnWiFi = false
        let manager = AudiobookSessionManager(
            appContainer: appContainer,
            reachabilityProvider: { MockReachability(initiallyConnected: false) },
            lcpContentDownloadTrigger: { [weak self] book in
                self?.triggeredBookIds.append(book.identifier)
            },
            lcpStreamingEnabledProvider: { true }
        )
        streamingSUTs.append(manager)
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await manager.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { _ in true }
        )

        XCTAssertTrue(triggeredBookIds.isEmpty,
            "the background-fetch policy refused (offline) — the gate must consult it rather than starting a transfer regardless")
        XCTAssertEqual(result, .proceed,
            "the open still proceeds; only the background fetch is deferred")
    }



    // MARK: - Gate behavior — TRIGGERS the download (the core fix)

    func testGate_contentMissing_triggersDownloadThenAwaits_landed() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        var awaitedBookId: String?

        let result = await sut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { id in
                awaitedBookId = id
                return true   // content lands after the trigger
            }
        )

        XCTAssertEqual(triggeredBookIds, [book.identifier],
            "The gate MUST trigger the content download exactly once for the missing book — the whole 323-Cause-1 fix is that it no longer merely polls")
        XCTAssertEqual(awaitedBookId, book.identifier,
            "The gate must await the SAME book's content after triggering")
        XCTAssertEqual(result, .landedAfterTrigger,
            "Content landing after the trigger must resolve to .landedAfterTrigger so the caller opens from the local package")
    }

    func testGate_contentMissing_awaitTimesOut_returnsUnavailable_butOnlyAfterTrigger() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await sut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { _ in false }   // download never lands
        )

        XCTAssertEqual(triggeredBookIds, [book.identifier],
            "Even on the unavailable path the download MUST have been triggered first — the dead-end is only legitimate AFTER a real download attempt")
        XCTAssertEqual(result, .contentUnavailable,
            "A genuine timeout AFTER the trigger resolves to .contentUnavailable (the existing 'Audiobook Unavailable' experience)")
    }

    func testGate_contentAlreadyLocal_doesNotTrigger_proceeds() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await sut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: true,
            awaitContentLanding: { _ in
                XCTFail("Must not await when the content is already local")
                return true
            }
        )

        XCTAssertTrue(triggeredBookIds.isEmpty,
            "Content already on disk — no re-download should be triggered")
        XCTAssertEqual(result, .proceed, "Already-local content proceeds straight to open")
    }

    func testGate_coldLoadRecovery_doesNotTrigger_proceeds() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        let result = await sut.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: true,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { _ in
                XCTFail("Cold-load recovery must not re-enter the gate's await")
                return true
            }
        )

        XCTAssertTrue(triggeredBookIds.isEmpty,
            "Cold-load recovery re-opens must not trigger a fresh download — the recovery path owns its own wait")
        XCTAssertEqual(result, .proceed)
    }

    // MARK: - The dead-end is unreachable without a trigger

    func testGate_neverReturnsUnavailable_whenGateNotApplicable() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        // Every combination in which the gate does NOT apply: it must proceed
        // and must never reach the "Audiobook Unavailable" dead-end, and must
        // never trigger a download.
        let notApplicable: [(cold: Bool, canOpen: Bool, local: Bool)] = [
            (false, true, true),    // content already local
            (true, true, false),    // cold-load recovery
            (false, false, false),  // not an LCP book
            (true, false, true),
        ]

        for scenario in notApplicable {
            triggeredBookIds = []
            let result = await sut.gateOnLCPContentDownload(
                for: book,
                isColdLoadRecovery: scenario.cold,
                canOpenLCPBook: scenario.canOpen,
                contentIsLocal: scenario.local,
                awaitContentLanding: { _ in false }
            )
            XCTAssertEqual(result, .proceed,
                "Gate-not-applicable \(scenario) must proceed, never surface unavailable")
            XCTAssertTrue(triggeredBookIds.isEmpty,
                "Gate-not-applicable \(scenario) must not trigger a download")
        }
    }

    // MARK: - Contract snapshot — trigger BEFORE await, ordered

    func testContract_gate_triggerThenAwait_landed() async {
        let log = CallLog()
        // Fixed identifier so the snapshot is deterministic across runs (the
        // gate takes `canOpenLCPBook` as an explicit param, so the distributor
        // type is irrelevant here — only the id flowing through matters).
        let book = TPPBookMocker.mockBook(identifier: "gate-contract-book", title: "Gate Contract Book")
        // Rebuild the SUT with a logging trigger so the CallLog captures order.
        let manager = AudiobookSessionManager(
            appContainer: appContainer,
            lcpContentDownloadTrigger: { b in log.record("triggerDownload", args: ["bookId": b.identifier]) },
            lcpStreamingEnabledProvider: { false }
        )
        defer { Task { await manager.stopPlayback(dismissPhoneUI: false) } }

        let result = await manager.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { id in
                log.record("awaitContentLanding", args: ["bookId": id])
                return true
            }
        )
        log.record("result", args: ["outcome": "\(result)"])

        ContractSnapshot.assert(log, named: "gate_triggerThenAwait_landed")
    }

    func testContract_gate_triggerThenAwait_timeout() async {
        let log = CallLog()
        let book = TPPBookMocker.mockBook(identifier: "gate-contract-book", title: "Gate Contract Book")
        let manager = AudiobookSessionManager(
            appContainer: appContainer,
            lcpContentDownloadTrigger: { b in log.record("triggerDownload", args: ["bookId": b.identifier]) },
            lcpStreamingEnabledProvider: { false }
        )
        defer { Task { await manager.stopPlayback(dismissPhoneUI: false) } }

        let result = await manager.gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: false,
            canOpenLCPBook: true,
            contentIsLocal: false,
            awaitContentLanding: { id in
                log.record("awaitContentLanding", args: ["bookId": id])
                return false
            }
        )
        log.record("result", args: ["outcome": "\(result)"])

        ContractSnapshot.assert(log, named: "gate_triggerThenAwait_timeout")
    }
}
