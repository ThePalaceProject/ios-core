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

@MainActor
final class AudiobookContentGateTests: XCTestCase {

    private var appContainer: AppContainer!
    private var triggeredBookIds: [String] = []
    private var sut: AudiobookSessionManager!

    override func setUp() async throws {
        try await super.setUp()
        triggeredBookIds = []
        appContainer = makeTestAppContainer()
        // Spy trigger: records every book the gate asks to (re)download, so a
        // test can prove the gate TRIGGERS rather than only polls.
        sut = AudiobookSessionManager(
            appContainer: appContainer,
            lcpContentDownloadTrigger: { [weak self] book in
                self?.triggeredBookIds.append(book.identifier)
            }
        )
    }

    override func tearDown() async throws {
        await sut?.stopPlayback(dismissPhoneUI: false)
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

    func testShouldTrigger_streamingEnabled_neverTriggers_acrossInputs() {
        // Streaming ON dominates every other input — no combination triggers a download.
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
            lcpContentDownloadTrigger: { b in log.record("triggerDownload", args: ["bookId": b.identifier]) }
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
            lcpContentDownloadTrigger: { b in log.record("triggerDownload", args: ["bookId": b.identifier]) }
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
