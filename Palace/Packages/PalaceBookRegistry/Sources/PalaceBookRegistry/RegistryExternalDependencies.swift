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
