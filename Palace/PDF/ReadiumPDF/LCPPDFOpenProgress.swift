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

    /// Percentage in [0, 95]. The denominator (total blocks to render
    /// page 1) is not known a priori, so the curve is `1 - exp(-x/N)`
    /// with N tuned so a small book climbs quickly and a large book
    /// keeps edging upward without stalling. Cached hits count toward
    /// progress — they ARE forward motion as far as PDFNavigator is
    /// concerned, the page is one step closer to rendering.
    var percentComplete: Int {
        let credit = Double(decryptedBlocks) + 0.5 * Double(cachedHits)
        let ratio = 1.0 - exp(-credit / 90.0)
        return min(95, Int((ratio * 100.0).rounded()))
    }

    func finish() {
        phase = .idle
        bookIdentifier = nil
    }
}
