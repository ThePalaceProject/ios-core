//
//  LCPPDFOpenProgress.swift
//  Palace
//
//  Observable progress reporter for the LCP-PDF open pipeline. Bound by
//  the loading overlay so the user sees what stage the open is in
//  (preparing → opening publication → decrypting content → loading
//  first page) and a live decrypt-block counter while PDFNavigator
//  walks the PDF cross-ref table.
//
//  The total number of decrypt blocks needed to render page 1 is not
//  known a priori — large Marketplace containers can take hundreds of
//  blocks, small one-pagers a handful. Rather than fake a percentage,
//  the overlay shows an indeterminate linear bar paired with the live
//  counter; the counter is honest progress (each tick proves the
//  pipeline is making forward motion) without pretending we know the
//  denominator.
//

import Foundation
import Combine

@MainActor
final class LCPPDFOpenProgress: ObservableObject {

    // `nonisolated` so background callers on the LCP-decrypt path
    // (TPPLCPClient.decrypt, LCPPDFDiskExtract.extract — both off the main
    // actor, ~7k calls/s during a PDF cross-ref walk) can reference the
    // singleton without a main-actor hop. Safe because a `@MainActor` class is
    // implicitly `Sendable` (the reference is immutable); the instance's state
    // stays main-actor-isolated and its recorder entry points are already
    // `nonisolated` with internal `Task { @MainActor }` hops.
    nonisolated static let shared = LCPPDFOpenProgress()

    /// Atomic flag readable from any actor — used by non-MainActor
    /// callers (cover prefetcher, etc.) that need to know whether an
    /// LCP PDF open is currently in flight without paying for a hop
    /// onto the main actor on every check. Mirrors the `phase != .idle`
    /// signal but is safe to read concurrently.
    nonisolated private static let openInProgressLock = NSLock()
    nonisolated(unsafe) private static var _openInProgress = false
    nonisolated static var isOpenInProgress: Bool {
        openInProgressLock.lock()
        defer { openInProgressLock.unlock() }
        return _openInProgress
    }
    nonisolated private static func setOpenInProgress(_ value: Bool) {
        openInProgressLock.lock()
        _openInProgress = value
        openInProgressLock.unlock()
    }

    enum Phase: String {
        case idle
        case preparing
        case openingPublication
        case decryptingContent
        /// Streaming the decrypted PDF to a temp file on disk. The
        /// disk-extract pipeline replaced direct-PDFNavigator render
        /// because the latter random-accessed the LCP stream and
        /// OOM'd on large books. `bytesExtracted / totalExtractBytes`
        /// gives a real % for this phase.
        case extractingToDisk
        case loadingFirstPage
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var decryptedBlocks: Int = 0
    @Published private(set) var decryptedBytes: Int = 0
    /// Blocks served from the LRU decrypt cache (no AES work needed).
    /// Counted separately so the progress bar credits them — a cached
    /// hit IS forward motion as far as PDFNavigator is concerned, the
    /// page is one step closer to rendering — without misleadingly
    /// padding the work-done counter.
    @Published private(set) var cachedHits: Int = 0
    /// Bytes written to the temp .pdf so far during the disk-extract
    /// phase. When `totalExtractBytes > 0` the progress bar derives a
    /// real percentage from this — first true % we can show.
    @Published private(set) var bytesExtracted: UInt64 = 0
    /// Estimated total bytes for the LCP-decrypted PDF (from
    /// `Resource.estimatedLength()`). 0 when unknown.
    @Published private(set) var totalExtractBytes: UInt64 = 0

    /// Identifier of the book whose open this reporter is tracking.
    /// Used by the loading overlay to ignore stale signals if a back-
    /// out-and-re-enter starts a different open.
    @Published private(set) var bookIdentifier: String?

    nonisolated private init() {}

    func begin(bookIdentifier: String) {
        self.bookIdentifier = bookIdentifier
        phase = .preparing
        decryptedBlocks = 0
        decryptedBytes = 0
        cachedHits = 0
        bytesExtracted = 0
        totalExtractBytes = 0
        Self.setOpenInProgress(true)
    }

    func setTotalExtractBytes(_ bytes: UInt64) {
        totalExtractBytes = bytes
    }

    nonisolated func recordExtractedBytes(_ count: Int) {
        Task { @MainActor in
            guard phase != .idle else { return }
            bytesExtracted += UInt64(count)
            if phase == .openingPublication || phase == .decryptingContent {
                phase = .extractingToDisk
            }
        }
    }

    func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    nonisolated func recordDecrypt(byteCount: Int, fromCache: Bool = false) {
        Task { @MainActor in
            // Only count blocks once we're actively in an LCP open. A
            // stray decrypt from elsewhere (e.g. an audiobook chunk on
            // a parallel read) should not bump this reporter.
            guard phase != .idle else { return }
            if fromCache {
                cachedHits += 1
            } else {
                decryptedBlocks += 1
                decryptedBytes += byteCount
            }
            // If a decrypt fires while we're still showing
            // "openingPublication", flip to "decryptingContent" so the
            // overlay text matches reality.
            if phase == .openingPublication {
                phase = .decryptingContent
            }
        }
    }

    /// Percentage in [0, 99]. Prefers the bytes-extracted denominator
    /// from the disk-extract pipeline when it's known — that gives the
    /// user a true, monotonically-accurate percentage. Falls back to
    /// the legacy decrypt-block curve only when no byte total is
    /// available (early startup, before `setTotalExtractBytes` fires,
    /// or in error paths where extraction never began).
    var percentComplete: Int {
        if totalExtractBytes > 0 {
            let ratio = Double(bytesExtracted) / Double(totalExtractBytes)
            return min(99, Int((ratio * 100.0).rounded()))
        }
        let credit = Double(decryptedBlocks) + 0.5 * Double(cachedHits)
        let expRatio = 1.0 - exp(-credit / 90.0)
        if expRatio < 0.80 {
            return Int((expRatio * 100.0).rounded())
        }
        let overshoot = credit - 145.0
        let extra = min(19.0, overshoot / 50.0)
        return min(99, Int((80.0 + extra).rounded()))
    }

    func finish() {
        phase = .idle
        bookIdentifier = nil
        Self.setOpenInProgress(false)
    }
}
