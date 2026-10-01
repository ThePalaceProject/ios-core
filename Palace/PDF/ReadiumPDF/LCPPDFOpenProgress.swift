//
//  LCPPDFOpenProgress.swift
//  Palace
//
//  Observable progress reporter for the LCP-PDF open pipeline, bound by the
//  loading overlay to show the current stage and progress.
//

import Foundation
import Combine

@MainActor
final class LCPPDFOpenProgress: ObservableObject {

    // `nonisolated` so high-frequency background callers on the decrypt path
    // can reference the singleton without a main-actor hop. Safe because a
    // `@MainActor` class is implicitly `Sendable`; its recorder entry points
    // hop to the main actor internally.
    nonisolated static let shared = LCPPDFOpenProgress()

    /// Lock-guarded flag readable from any actor (e.g. the cover prefetcher),
    /// mirroring `phase != .idle` without a main-actor hop per check.
    private final class OpenInProgressFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
    nonisolated private static let openInProgressFlag = OpenInProgressFlag()
    nonisolated static var isOpenInProgress: Bool {
        openInProgressFlag.isSet
    }
    nonisolated private static func setOpenInProgress(_ value: Bool) {
        openInProgressFlag.set(value)
    }

    enum Phase: String {
        case idle
        case preparing
        case openingPublication
        case decryptingContent
        /// Streaming the decrypted PDF to a temp file on disk (see
        /// `LCPPDFDiskExtract`). `bytesExtracted / totalExtractBytes` gives a
        /// real % for this phase.
        case extractingToDisk
        case loadingFirstPage
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var decryptedBlocks: Int = 0
    @Published private(set) var decryptedBytes: Int = 0
    /// Blocks served from the LRU decrypt cache. Counted separately so the
    /// progress bar credits them without padding the work-done counter.
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

    /// Percentage in [0, 99]. Uses the bytes-extracted denominator when known,
    /// otherwise falls back to the decrypt-block curve.
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
