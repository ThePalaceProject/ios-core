//
//  RegistryExternalDependencies.swift
//  PalaceBookRegistry
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceCatalog

/// The download-center surface `BookRegistrySync` consumes, injected app-side
/// (god-class decomposition Wave 2b). `MyBooksDownloadCenter` conforms via an
/// app-target extension.
///
/// `contentFileSatisfied` / `lcpContentFileMissing` exist because SPM targets do
/// NOT inherit the app's `LCP` compilation condition — the `#if LCP` /
/// `LCPAudiobooks.canOpenBook` probe logic that used to live inline in
/// `checkIfBookFileExists` MUST live in the app-side adapter. Palace-noDRM's
/// adapter returns the non-LCP behavior (plain file existence / `false`).
public protocol RegistryDownloadServicing: Sendable {
    func fileUrl(for book: TPPBook, account: String?) -> URL?
    func startDownload(for book: TPPBook)
    func deleteLocalContent(forBook book: TPPBook, account: String?)
    func redownloadLCPContentFile(for book: TPPBook)

    /// Whether the book's content is satisfied on disk. Encapsulates the app's
    /// `#if LCP` license-vs-content rule: an LCP audiobook is "satisfied" as soon
    /// as its `.lcpl` license exists (playable via streaming) even if the `.lcpa`
    /// content file is absent; every other book requires the content file itself.
    /// noDRM returns plain file existence.
    func contentFileSatisfied(for book: TPPBook, account: String) -> Bool

    /// Whether an LCP audiobook is playable-via-streaming but missing its local
    /// `.lcpa` content file — the signal to schedule a silent background
    /// re-download (PP-3704). LCP-only; noDRM returns `false`.
    func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool

    /// What is actually on disk for a book, as load-time reconciliation needs it.
    ///
    /// Strictly stronger than `contentFileSatisfied`, which answers a weaker
    /// question: for an LCP audiobook it reports `true` on the `.lcpl` LICENSE
    /// alone, because while streaming worked a license WAS enough to play. With
    /// streaming unusable upstream that assumption is false, and it was
    /// denormalized across the reconciliation arms — each independently reading
    /// "a file exists" as "the book is playable". Three separate defects came out
    /// of that, all shaped the same way: an interrupted or cancelled LCP download
    /// promoted to `.downloadSuccessful`, offering Listen with no audio behind it.
    ///
    /// Note this is NOT `lcpContentFileMissing` inverted. That predicate does not
    /// check whether the license exists, so it cannot separate "license present,
    /// content missing" (recoverable — re-fetch the content) from "nothing on
    /// disk at all" (a fresh borrow, or a failed first fulfillment). Those two
    /// map to different reconciliation outcomes, so they need distinct cases.
    func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence

    /// True while a transfer for this book is running, so reconciliation leaves an
    /// in-flight record alone instead of scheduling a duplicate.
    ///
    /// Cannot be derived from `downloadInfo` alone app-side, which is why it is a
    /// seam member: an LCP `.lcpa` transfer runs on Readium's own `URLSession` and
    /// never registers there, so `downloadInfo` reports "nothing in flight" for the
    /// entire multi-minute fulfillment. The adapter also consults the progress
    /// reporter. Without both, reconciliation reads a license with no content as a
    /// stranded book and re-downloads something already downloading — measured as a
    /// duplicated 1.8 GB transfer on a fresh borrow, discarded on arrival.
    func isDownloadInFlight(for book: TPPBook) -> Bool
}

/// What is on disk for a book: the `.lcpl`-license-only case distinguished from
/// real playable content. Resolved app-side (the `#if LCP` probe cannot live in
/// this package) and consumed by `BookRegistrySync.reconcile`.
public enum RegistryContentPresence: Equatable, Sendable {
    /// Nothing on disk.
    case absent
    /// LCP audiobook whose `.lcpl` license is present but whose `.lcpa` content
    /// package is not. Not playable; recoverable by re-fetching the content.
    case licenseOnly
    /// Real, playable content on disk.
    case present
}

/// The external collaborators `BookRegistrySync` / `BookRegistryStore` resolve
/// lazily at call time. Each closure carries the SAME deferred-resolution
/// semantics the pre-extraction inline `AppContainer.production()` closures had —
/// they are supplied by the composition root instead of hard-coded in the engine,
/// so the package has no edge to AppContainer / downloads / accounts / settings.
public struct RegistryExternalDependencies: Sendable {
    /// Lazily resolves the download service (deferred because the download center
    /// reads the registry back for its own defaults — resolving at engine
    /// construction time would deadlock the composition-root init chain).
    public let downloadService: @Sendable () -> any RegistryDownloadServicing
    /// Lazily resolves the loans-feed fetcher (the live `OPDSFeedService`).
    public let loansFeedFetcher: @Sendable () -> any OPDSFeedFetching
    /// Identifiers of side-loaded books — exempt from loans-feed reconciliation.
    public let sideloadedIdentifiers: @Sendable () -> Set<String>
    /// The registry directory for an account (the `TPPAccountUUIDs[0]` root-vs-subdir
    /// path-layout rule + error logging), resolved app-side.
    public let registryDirectory: @Sendable (_ accountID: String) -> URL?
    /// Fired when a reconciled record's availability changed (drives the app's
    /// push-notification comparison). App-side no-ops when notifications are off.
    public let onAvailabilityChange: @Sendable (_ cachedRecord: TPPBookRegistryRecord, _ newBook: TPPBook) -> Void

    public init(
        downloadService: @escaping @Sendable () -> any RegistryDownloadServicing,
        loansFeedFetcher: @escaping @Sendable () -> any OPDSFeedFetching,
        sideloadedIdentifiers: @escaping @Sendable () -> Set<String>,
        registryDirectory: @escaping @Sendable (_ accountID: String) -> URL?,
        onAvailabilityChange: @escaping @Sendable (_ cachedRecord: TPPBookRegistryRecord, _ newBook: TPPBook) -> Void
    ) {
        self.downloadService = downloadService
        self.loansFeedFetcher = loansFeedFetcher
        self.sideloadedIdentifiers = sideloadedIdentifiers
        self.registryDirectory = registryDirectory
        self.onAvailabilityChange = onAvailabilityChange
    }
}
