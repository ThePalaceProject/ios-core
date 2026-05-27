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

    static let shared = LCPPDFOpenProgress()

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

    /// Identifier of the book whose open this reporter is tracking.
    /// Used by the loading overlay to ignore stale signals if a back-
    /// out-and-re-enter starts a different open.
    @Published private(set) var bookIdentifier: String?

    private init() {}

    func begin(bookIdentifier: String) {
        self.bookIdentifier = bookIdentifier
        phase = .preparing
        decryptedBlocks = 0
        decryptedBytes = 0
        cachedHits = 0
        Self.setOpenInProgress(true)
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

    /// Percentage in [0, 99]. The denominator (total blocks to render
    /// the first page) is not known a priori — small one-page Marketplace
    /// PDFs need a few dozen decrypts, large textbooks need thousands —
    /// so the curve is monotonic without a hard plateau.
    ///
    /// Stage 1 (0–80%): exponential `1 - exp(-x/N)` so a small book
    /// climbs fast and the user sees real motion in the first few
    /// seconds.
    /// Stage 2 (80–99%): linear continuation that keeps creeping by
    /// ~1% every N additional blocks. Prevents the "stuck at 95%"
    /// look that a pure exponential produces on large books — the
    /// bar visibly inches forward right up until first paint.
    ///
    /// Cached hits count at 50% weight: they ARE forward motion (the
    /// page is one step closer to rendering, just for free) but
    /// shouldn't make the bar lurch on a warm-cache re-open.
    var percentComplete: Int {
        let credit = Double(decryptedBlocks) + 0.5 * Double(cachedHits)
        // Exponential climb to 80%.
        let expRatio = 1.0 - exp(-credit / 90.0)
        if expRatio < 0.80 {
            return Int((expRatio * 100.0).rounded())
        }
        // Beyond exp ≈ 80% (around 145 credit), linearly approach 99%.
        // Every additional 50 credit adds ~1% — so a 1000-block book
        // sees the bar drift from 80% → 99% over 17 stages, never
        // stalling visually.
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
