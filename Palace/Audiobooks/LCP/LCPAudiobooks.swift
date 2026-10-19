//
//  LCPAudiobooks.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 16.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#if LCP

import Foundation
import CryptoKit
import PalaceLogging
import PalaceCatalog
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumLCP
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

/// - Sendable invariant: instances are safe to share across concurrency
///   domains (they are captured by the `@Sendable` closures
///   `publicationCacheQueue.async`/`DispatchQueue.global().async` schedules,
///   and by the decrypt/load `Task`s) because:
///   1. Every stored dependency (`audiobookUrl`, `licenseUrl`,
///      `assetRetriever`, `publicationOpener`, `httpClient`,
///      `publicationCacheQueue`) is a `let` — immutable after `init`.
///   2. Every piece of mutable state (`cachedPublication`,
///      `currentPrefetchTask`, `isReleased`) is read and written ONLY through
///      the serial `publicationCacheQueue` (`.sync`/`.async`). No mutable
///      property is touched off that queue, so there is no unsynchronized
///      shared mutation.
///   `final` keeps the invariant intact — a subclass cannot add
///   unsynchronized stored state. Hence `@unchecked Sendable` rather than a
///   compiler-checked conformance (the Readium dependency types are not
///   Sendable-audited).
@objc final class LCPAudiobooks: NSObject, @unchecked Sendable {

    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    private let audiobookUrl: AbsoluteURL
    private let licenseUrl: URL?
    private let archiveReadClient: PartialArchiveCachingHTTPClient
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener
    private let httpClient: HTTPClient

    private var cachedPublication: Publication?
    private let publicationCacheQueue = DispatchQueue(label: "org.thepalaceproject.lcpaudiobooks.publicationcache")

    /// The tracks a chapter load asked the length cache for and did not find,
    /// oldest first. The oldest outstanding ask is the chapter being waited on:
    /// the player asks for the one it is about to play before the items it
    /// prefetches behind it.
    private let demandedTracks = DemandedTracks()

    /// How many track-length resolutions are in flight for this archive.
    ///
    /// A chapter waits for a length only while one is running: with nothing
    /// running no answer is coming, and Readium's probe is the only one left.
    /// A count rather than a flag because the open's resolution and the
    /// resolution it calls both announce themselves, and the inner one ending
    /// must not say the outer one has.
    private let trackLengthResolutions = WorkInFlight()
    private var currentPrefetchTask: Task<Void, Never>?
    /// The background resolution of this archive's track lengths.
    private var trackLengthTask: Task<Void, Never>?

    /// Once set, the instance is a dead one-shot: no new Publication may be opened
    /// through contentDictionary, decrypt, or startPrefetch. A previously opened
    /// Publication held via cachedPublication has already been dropped.
    ///
    /// Why: a stale AudiobookManager's decryptor chain could otherwise race the
    /// next audiobook's publicationOpener.open() on the same .lcpa, which
    /// deadlocks inside Readium and surfaces as the "opening third audiobook
    /// hangs" bug.
    private var isReleased: Bool = false

    /// Initialize for an LCP audiobook
    /// - Parameter audiobookUrl: can be a local `.lcpa` package URL OR an `.lcpl` license URL for streaming
    /// - Parameter licenseUrl: optional license URL for streaming authentication (deprecated, use audiobookUrl)
    @objc init?(for audiobookUrl: URL, licenseUrl: URL? = nil) {

        if let fileUrl = FileURL(url: audiobookUrl) {
            self.audiobookUrl = fileUrl
        } else if let httpUrl = HTTPURL(url: audiobookUrl) {
            self.audiobookUrl = httpUrl
        } else {
            return nil
        }

        self.licenseUrl = licenseUrl ?? (audiobookUrl.pathExtension.lowercased() == "lcpl" ? audiobookUrl : nil)

        // One client, owned by the LCP service, because the range store holds an
        // exclusive advisory lock on its directory: a second client for the same
        // archive is refused and reads through for the rest of the session. The
        // service's ContentProtection retrieves the streamed publication through
        // this same client, and the container it returns is what every archive read
        // for playback goes through (PP-5367).
        let httpClient = lcpService.archiveReadClient
        // Retained so the open can report how many ranged requests it cost.
        // `PublicationOpener.open` is a single await, so the only way to tell
        // licence-validation time from archive-read time is to count the reads
        // across it.
        self.archiveReadClient = httpClient
        self.httpClient = httpClient
        self.assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let contentProtection = lcpService.contentProtection else {
            return nil
        }

        let parser = DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )

        self.publicationOpener = PublicationOpener(
            parser: parser,
            contentProtections: [contentProtection]
        )
    }

    @objc func contentDictionary(completion: @escaping @Sendable (_ json: NSDictionary?, _ error: NSError?) -> Void) {
        if isReleasedSnapshot() {
            DispatchQueue.main.async {
                completion(nil, Self.releasedError())
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.loadContentDictionary { json, error in
                // `NSDictionary` / `NSError` are not Sendable-audited, so
                // capturing `json` / `error` into the `main.async` `@Sendable`
                // closure trips `sending … risks data races`. Snapshot the pair
                // into a Sendable carrier for the single main-thread hop; the
                // values are freshly produced by the load and consumed once.
                let resultBox = LCPContentResultBox(json: json, error: error)
                DispatchQueue.main.async {
                    completion(resultBox.json, resultBox.error)
                }
            }
        }
    }

    private func isReleasedSnapshot() -> Bool {
        publicationCacheQueue.sync { isReleased }
    }

    private static func releasedError() -> NSError {
        NSError(
            domain: "Palace.LCPAudiobooks",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "LCPAudiobooks instance has been released"]
        )
    }

    private func loadContentDictionary(completion: @escaping @Sendable (_ json: NSDictionary?, _ error: NSError?) -> Void) {
        if isReleasedSnapshot() {
            completion(nil, Self.releasedError())
            return
        }

        publicationCacheQueue.async {
            self.currentPrefetchTask?.cancel()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            if self.isReleasedSnapshot() {
                completion(nil, Self.releasedError())
                return
            }

            var urlToOpen: AbsoluteURL = audiobookUrl
            if let licenseUrl {
                if let fileUrl = FileURL(url: licenseUrl) {
                    urlToOpen = fileUrl
                } else if let httpUrl = HTTPURL(url: licenseUrl) {
                    urlToOpen = httpUrl
                } else {
                    completion(nil, NSError(domain: "LCPAudiobooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid license URL"]))
                    return
                }
            }

            let openStartedAt = Date()
            // A hung open records nothing from the timing below, because that runs
            // after an await which never returns — and a Readium deadlock on
            // publicationOpener.open is on record for this path (the "opening third
            // audiobook hangs" defect this type's one-shot guard exists for). A
            // stalled open and a slow one need opposite fixes, so the stall has to
            // announce itself from somewhere that is still running.
            let openWatchdog = Task { [threshold = Self.slowPublicationOpenThreshold] in
                try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                Log.error(#file, String(
                    format: "LCP publication open has not returned after %.0fs; the chapter fails at 30s having served no bytes",
                    threshold
                ))
            }
            defer { openWatchdog.cancel() }
            let result = await assetRetriever.retrieve(url: urlToOpen)
            let retrievedAt = Date()

            switch result {
            case .success(let asset):
                if Task.isCancelled { return }

                var credentials: String?
                if let licenseUrl = licenseUrl, licenseUrl.isFileURL {
                    credentials = try? String(contentsOf: licenseUrl)
                }

                let activityBefore = archiveReadClient.upstreamActivity
                let result = await publicationOpener.open(asset: asset, allowUserInteraction: true, credentials: credentials, sender: nil)
                let openedAt = Date()
                let openDuration = openedAt.timeIntervalSince(openStartedAt)
                let readCost = archiveReadClient.upstreamActivity.delta(since: activityBefore)
                if Self.shouldReportSlowPublicationOpen(duration: openDuration) {
                    // At `.error` deliberately: only error and fault reach the
                    // on-device log the patron can export, and an open this slow is
                    // what they report as a book that never starts.
                    Log.error(#file, String(
                        format: "LCP publication open took %.1fs (asset retrieve %.1fs, open %.1fs); the streaming player fails the chapter at 30s",
                        openDuration,
                        retrievedAt.timeIntervalSince(openStartedAt),
                        openedAt.timeIntervalSince(retrievedAt)
                    ))
                }
                // Outside the slow-open branch deliberately. Gating this on a
                // slow open missed the case the patron actually reported: a
                // fast open followed by a slow chapter change. One line per
                // open is affordable and the cheap case is itself the finding.
                Log.error(#file, String(
                    format: "LCP open archive reads: %d origin request(s) for %d bytes, %d store serve(s) for %d bytes, open %.1fs",
                    readCost.originRequests,
                    readCost.originBytes,
                    readCost.storeServes,
                    readCost.storeBytes,
                    openDuration
                ))

                switch result {
                case .success(let publication):

                    if Task.isCancelled { return }
                    self.publicationCacheQueue.async {
                        self.cachedPublication = publication
                    }
                    self.startResolvingTrackLengths(for: publication)

                    if let jsonManifestString = publication.jsonManifest, let jsonData = jsonManifestString.data(using: .utf8),
                       let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
                        completion(jsonObject, nil)
                    } else {
                        let links = publication.readingOrder.map { link in
                            let hrefString = String(describing: link.href)
                            let typeString = link.mediaType.map { String(describing: $0) } ?? "audio/mpeg"
                            return [
                                "href": hrefString,
                                "type": typeString
                            ]
                        }
                        let minimal: [String: Any] = [
                            "metadata": [
                                "identifier": UUID().uuidString,
                                "title": String(describing: publication.metadata.title)
                            ],
                            "readingOrder": links
                        ]
                        completion(minimal as NSDictionary, nil)
                    }
                case .failure(let error):
                    completion(nil, LCPAudiobooks.nsError(for: error))
                }

            case .failure(let error):
                completion(nil, LCPAudiobooks.nsError(for: error))
            }

            self.publicationCacheQueue.async {
                if self.currentPrefetchTask?.isCancelled == true { self.currentPrefetchTask = nil }
            }
        }

        publicationCacheQueue.async {
            self.currentPrefetchTask = task
        }
    }

    /// Check if the book is LCP audiobook. Delegates to `hasLCPAcquisition(_:)`
    /// so all three OPDS feed shapes (`/loans/` XML, `/groups/` JSON, and the
    /// OPDS-catalog wrapping shape) resolve correctly — PP-4407 / PP-4454.
    /// - Parameter book: audiobook
    /// - Returns: `true` if the book is an LCP DRM protected audiobook, `false` otherwise
    @objc static func canOpenBook(_ book: TPPBook) -> Bool {
        return hasLCPAcquisition(book)
    }

    /// Returns `true` iff `book` is an LCP-protected audiobook, regardless of
    /// which OPDS feed shape Marketplace happened to populate it from. Unlike
    /// `canOpenBook(_:)` — which only matches the `/loans/` XML shape that
    /// places the LCP MIME at the top of `defaultAcquisition.type` — this
    /// predicate also walks `indirectAcquisitions[*].type` recursively so the
    /// `/groups/` JSON feed shape (top-level `application/opds-publication+json`
    /// with the LCP license nested one or more levels deep) is caught.
    ///
    /// This is the load-bearing fix for the PP-4407 regression class. Ported
    /// from the 3.0.3 hotfix commit `ca2ff13b6`, which only landed on the
    /// 3.0.x release branch and was never forward-merged to develop. The
    /// `defaultBookContentType == .audiobook` clause is required so LCP-typed
    /// EPUBs and PDFs do NOT match here — only audiobooks.
    @objc static func hasLCPAcquisition(_ book: TPPBook) -> Bool {
        guard book.defaultBookContentType == .audiobook,
              let acquisition = book.defaultAcquisition else {
            return false
        }
        if acquisition.type == expectedAcquisitionType {
            return true
        }
        return indirectChainContainsLCP(acquisition.indirectAcquisitions)
    }

    private static func indirectChainContainsLCP(_ chain: [TPPOPDSIndirectAcquisition]) -> Bool {
        for node in chain {
            if node.type == expectedAcquisitionType {
                return true
            }
            if indirectChainContainsLCP(node.indirectAcquisitions) {
                return true
            }
        }
        return false
    }

    /// Creates an NSError for Objective-C code
    /// - Parameter error: Error object
    /// - Returns: NSError object
    private static func nsError(for error: Error) -> NSError {
        return NSError(domain: "Palace.LCPAudiobooks", code: 0, userInfo: [
            NSLocalizedDescriptionKey: error.localizedDescription,
            "Error": error
        ])
    }
}

/// This conformance is deliberately NOT isolated, and must stay that way.
///
/// `LCPStreamingProvider` inherits `DRMDecryptor`, so isolating the conformance
/// isolates decryption too: `error: main actor-isolated conformance of
/// 'LCPAudiobooks' to 'DRMDecryptor' cannot be used in nonisolated context`.
/// Decryption legitimately runs off-main, and `getPublication()` is called from
/// AVFoundation's resource-loader thread inside a polling loop in
/// `LCPResourceLoaderDelegate`.
///
/// Two shapes were tried and both failed to compile — do not reintroduce them:
///   1. `@MainActor` on `setupStreamingFor` alone → Swift then demands the whole
///      conformance be isolated.
///   2. `extension LCPAudiobooks: @MainActor LCPStreamingProvider` → the
///      `DRMDecryptor` error above.
///
/// What works: a nonisolated witness satisfies the `@MainActor` requirement
/// (the permissive direction), and the one statement touching main-actor state
/// hops explicitly. See `setupStreamingFor` below.
// MARK: - Partial archive store

extension LCPAudiobooks {

    /// Whether an LCP publication open was slow enough to record.
    ///
    /// The streaming player fails a chapter after 30 s with "Timed out waiting
    /// for LCP publication to load" and the resource loader gives up at 25 s, so
    /// an open approaching either is what a patron experiences as a book that
    /// never starts. Nothing recorded how long the open took, which left the
    /// device logs saying only that the deadline passed.
    ///
    /// Pure so the threshold is testable and a flipped comparison is caught.
    static func shouldReportSlowPublicationOpen(
        duration: TimeInterval,
        threshold: TimeInterval = LCPAudiobooks.slowPublicationOpenThreshold
    ) -> Bool {
        duration >= threshold
    }

    /// Well below the 25 s loader deadline, so an open heading for a failure is
    /// recorded before the failure and not only after it.
    static let slowPublicationOpenThreshold: TimeInterval = 10

    /// Where a streamed archive's retained byte ranges live.
    ///
    /// Deliberately NOT under the download destination's parent. The background
    /// package fetch finishes with `moveItem(at:to:)` over that path, and a
    /// rename across a file this store holds descriptors on would leave it
    /// writing to an unlinked inode: reads and writes keep succeeding, the
    /// journal keeps recording, and every served byte comes from a file nothing
    /// can reach. Undetectable downstream, because the AES-CBC payload is
    /// unauthenticated and an unwritten extent reads as zeros of exactly the
    /// requested length.
    static func partialArchivesRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("PartialArchives", isDirectory: true)
    }

    /// The directory for one archive, keyed on its content URL.
    ///
    /// The URL is the only identifier available here — `init(for:licenseUrl:)` is
    /// handed URLs and never a `TPPBook` — and it is stable and unique per
    /// publication: the observed shape carries no query string, signature or
    /// expiry. A signed URL would break the key silently into "no hits, one
    /// directory per fetch", so that case is logged rather than guessed at.
    static func archiveStoreDirectory(for url: HTTPURL) throws -> URL {
        if url.url.query?.isEmpty == false {
            ATLog(.warn, "LCP archive URL carries a query string; the range store key may not be stable across fulfilments")
        }
        let digest = SHA256.hash(data: Data(url.string.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return try partialArchivesRoot().appendingPathComponent(name, isDirectory: true)
    }

    /// Opens the store for an archive whose true length has just been learned
    /// from a `Content-Range`.
    ///
    /// A recorded length that disagrees with the server is resolved by deleting
    /// and starting over: the alternative is writing bytes from one archive at
    /// offsets interpreted against another's length, which is the one direction
    /// the store's design forbids. A refetch costs egress; accepting costs the
    /// patron silence from a file that looks healthy.
    static func makeArchiveRangeStore(url: HTTPURL, totalSize: UInt64?) throws -> ArchiveRangeStore? {
        let dir = try archiveStoreDirectory(for: url)

        // With no length yet, answer only for an archive whose ranges are already
        // on disk. Otherwise the first read of a book read before would fetch a
        // whole 6 MB window just to learn how long the archive is, which is the
        // cost this store exists to avoid. Returning nil is not an error: the
        // client asks again once a response has reported a length.
        guard let totalSize else {
            guard let recorded = PartialArchiveStore.recordedTotalSize(in: dir) else { return nil }
            evictArchiveStoresOtherThan(dir)
            // `try?`, not `try`: a throw here marks the archive refused for the
            // life of the client, which would switch caching off for the whole
            // session over a transient failure to take the lock.
            return try? PartialArchiveStore.open(directory: dir, totalSize: recorded)
        }
        // Bound the disk to one archive. An LCP archive is 1-2 GB, so an
        // unbounded set of these is a new defect rather than a fix, and the
        // eviction that return would otherwise drive is not available here:
        // `init(for:licenseUrl:)` is handed URLs and never a `TPPBook`, so this
        // layer cannot know which loan a directory belongs to. One store at a
        // time is bounded without needing that identity. A patron who alternates
        // between two streamed books refetches on each switch, which costs
        // egress rather than correctness; widening this needs the book
        // identifier plumbed in and an LRU, and is deliberately not done here.
        evictArchiveStoresOtherThan(dir)
        do {
            return try PartialArchiveStore.open(directory: dir, totalSize: totalSize)
        } catch PartialArchiveStoreError.totalSizeMismatch(let recorded, let requested) {
            ATLog(.warn, "LCP range store length changed (recorded \(recorded), server \(requested)); discarding and starting over")
            try? FileManager.default.removeItem(at: dir)
            return try PartialArchiveStore.open(directory: dir, totalSize: totalSize)
        }
    }

    /// The lock file a `PartialArchiveStore` holds open for its whole lifetime.
    ///
    /// Spelled out here because the toolkit's own `lockFileName` is internal to
    /// that module. It must stay in step with
    /// `PalaceAudiobookToolkit.PartialArchiveStore.lockFileName`.
    static let archiveStoreLockFileName = "archive.lock"

    /// Whether an open `PartialArchiveStore` still holds `directory`.
    ///
    /// The store takes `flock(LOCK_EX)` on its lock file and keeps it until it
    /// closes, so a non-blocking exclusive attempt answers the question: it is
    /// refused only while a holder exists. `flock` belongs to the open file
    /// description rather than the process, so a store open in this same
    /// process is detected too — which is the case that matters here, since the
    /// store being stepped on belongs to the previous book in this session.
    ///
    /// The lock file outlives the store that wrote it, so presence alone cannot
    /// stand in for a holder, and the probe opens without `O_CREAT` so a
    /// directory with no lock file reports free rather than gaining one on the
    /// way out.
    static func archiveStoreIsHeld(at directory: URL) -> Bool {
        let lockPath = directory.appendingPathComponent(archiveStoreLockFileName).path
        let descriptor = Darwin.open(lockPath, O_RDONLY)
        guard descriptor != -1 else { return false }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            // `EWOULDBLOCK` is the one errno a live holder produces. Anything
            // else means the question could not be asked, and reporting that as
            // held would strand 1-2 GB per archive on disk for the life of the
            // install, so the bound on disk wins and the entry stays evictable.
            guard errno == EWOULDBLOCK else {
                ATLog(.warn, "Could not probe an LCP archive range store's lock (errno \(errno)); treating it as free")
                return false
            }
            return true
        }
        // Released rather than left to the `close`, which would drop it anyway:
        // holding it any longer makes the probe itself the next caller's blocker.
        flock(descriptor, LOCK_UN)
        return false
    }

    /// Keeps one archive's ranges on disk, plus any an open store still holds.
    ///
    /// Called before opening, so the store being opened is never the one
    /// removed. A directory whose store is still open is skipped: `removeItem`
    /// ignores the `flock` the store holds, so unlinking it leaves that store
    /// writing and fsyncing into an inode no path reaches. Its reads keep
    /// answering from the same inode, so nothing surfaces as an error — every
    /// window it caches is simply discarded when the session ends and refetched
    /// from the origin, which on a slow link is the chapter wait this store
    /// exists to remove.
    ///
    /// Skipping is bounded by the holder, not by the directory: a store that has
    /// closed, or one left behind by a previous launch, holds nothing and is
    /// evicted, so the disk stays bounded to the archives actually in use.
    static func evictArchiveStoresOtherThan(_ keep: URL) {
        guard let root = try? partialArchivesRoot() else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != keep.lastPathComponent {
            guard !archiveStoreIsHeld(at: entry) else {
                ATLog(.info, "Left a retained LCP archive range store in place: a store still holds it")
                continue
            }
            do {
                try fm.removeItem(at: entry)
                ATLog(.info, "Evicted a retained LCP archive range store to keep one on disk")
            } catch {
                ATLog(.warn, "Could not evict a retained LCP archive range store: \(error.localizedDescription)")
            }
        }
    }

    /// The remote archive URL a licence file points at.
    ///
    /// The range store is keyed on the publication URL, and the whole-archive
    /// re-download is handed the licence on disk rather than that URL, so the
    /// key is derived here — beside `archiveStoreDirectory`, which consumes it.
    static func publicationURL(inLicenseAt licenseURL: URL) -> HTTPURL? {
        guard
            let data = try? Data(contentsOf: licenseURL),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let links = root["links"] as? [[String: Any]]
        else { return nil }

        for link in links {
            // Every licence observed spells `rel` as a single string; the LCP
            // schema also admits an array. Both are read, so a conforming
            // licence cannot answer "no publication" and strand its store.
            let rels: [String]
            switch link["rel"] {
            case let single as String: rels = [single]
            case let many as [String]: rels = many
            default: continue
            }
            guard
                rels.contains("publication"),
                let href = link["href"] as? String,
                let url = HTTPURL(string: href)
            else { continue }
            return url
        }
        return nil
    }

    /// Removes the retained range store of one archive: the publication the
    /// licence at `licenseURL` names.
    ///
    /// `removeAllArchiveStores` is not usable on the transfer-completed path.
    /// `evictArchiveStoresOtherThan` keeps a single store on disk, and on that
    /// path the surviving store belongs to whichever book is being streamed —
    /// not to the book whose whole-archive transfer just finished. Clearing the
    /// root there discarded the windows the streamed book's next chapter would
    /// have been served from, so each chapter change refetched from the origin.
    ///
    /// A directory an open store still holds is left in place, for the reason
    /// `evictArchiveStoresOtherThan` leaves one: `removeItem` ignores the
    /// `flock`, so unlinking it leaves that reader writing into an inode no
    /// path reaches.
    static func removeArchiveStore(forLicenseAt licenseURL: URL) {
        guard let publicationURL = publicationURL(inLicenseAt: licenseURL) else {
            ATLog(.warn, "No archive URL in this licence; leaving its retained range store in place")
            return
        }
        guard let directory = try? archiveStoreDirectory(for: publicationURL) else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            // Not an error on the transfer path, where there may simply be no
            // retained ranges. On the delete path it means the licence's
            // publication href does not key the directory the streaming client
            // created — `archiveStoreDirectory` warns that a query-bearing URL
            // may not be stable across fulfilments — and the ranges are then
            // left behind, so it is worth being able to see it.
            ATLog(.info, "No retained range store is keyed by this licence's archive URL")
            return
        }
        guard !archiveStoreIsHeld(at: directory) else {
            ATLog(.info, "An open store still holds this archive's range store; leaving it in place")
            return
        }
        do {
            try fm.removeItem(at: directory)
            ATLog(.info, "Removed the retained range store of an archive now stored whole")
        } catch {
            ATLog(.warn, "Could not remove a retained LCP archive range store: \(error.localizedDescription)")
        }
    }

    /// Removes every retained archive range store whose directory no open store
    /// holds.
    ///
    /// The fallback for a content delete whose licence cannot be read, so the
    /// archive URL that keys the store is unavailable — see
    /// `removeArchiveStore(forLicenseAt:)` for the keyed path this defers to.
    ///
    /// A held directory is left alone. `PartialArchiveStore` keeps its archive
    /// descriptor open for its whole lifetime, so unlinking the directory frees
    /// no bytes while that reader lives and leaves its writes landing in a path
    /// nothing can reach — and on this path the holder is usually a DIFFERENT
    /// book, streaming right now.
    ///
    /// The residual, stated plainly: the bytes stay until the holder closes and
    /// something evicts the directory. Unlinking would have freed them when the
    /// descriptor closed, without needing that later trigger, so skipping is
    /// weaker on reclaim and stronger on not breaking a live reader.
    /// `evictArchiveStoresOtherThan` is what reclaims it, at the next open of
    /// another archive.
    @objc static func removeAllArchiveStores() {
        guard let root = try? partialArchivesRoot() else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            guard !archiveStoreIsHeld(at: entry) else {
                ATLog(.info, "An open store holds this LCP archive range store; leaving it for eviction once the holder closes")
                continue
            }
            do {
                try fm.removeItem(at: entry)
                ATLog(.info, "Removed a retained LCP archive range store on content deletion")
            } catch {
                ATLog(.warn, "Could not remove a retained LCP archive range store: \(error.localizedDescription)")
            }
        }
    }
}

extension LCPAudiobooks: LCPStreamingProvider {

    nonisolated public func getPublication() -> Publication? {
        return publicationCacheQueue.sync {
            return cachedPublication
        }
    }

    nonisolated public func supportsStreaming() -> Bool {
        return true
    }

    /// Whether this instance was opened from the package on disk rather than
    /// from a licence that streams it.
    ///
    /// `licenseUrl` is the discriminator, derived in `init` from the source's
    /// extension: a `.lcpl` sets it, a `.lcpa` leaves it nil. The URL's scheme
    /// cannot answer this. Every source the adapter hands over is a `file:`
    /// URL — the package, the cached licence sibling, and the licence it
    /// re-downloads and writes to disk — so `audiobookUrl.fileURL != nil` is
    /// true of the streaming case too, and asking it that way turned the
    /// loader's per-track buffer off everywhere.
    /// Namespace for the plaintext-length cache: the archive's own store key,
    /// so two books cannot collide and a re-fulfilment of the same archive
    /// reuses what was already learned.
    private var plaintextLengthKeyPrefix: String? {
        guard let licenseUrl, licenseUrl.isFileURL,
              let publication = Self.publicationURL(inLicenseAt: licenseUrl),
              let directory = try? Self.archiveStoreDirectory(for: publication)
        else { return nil }
        return "LCPTrackLength.\(directory.lastPathComponent)."
    }

    /// Stored in `UserDefaults` rather than beside the archive: the value is one
    /// integer per track, it must survive the range store being evicted (the
    /// length does not change when the bytes are reclaimed), and a read happens
    /// on the chapter-change path where opening a file would be the thing being
    /// avoided.
    /// The player's ask. A miss is recorded as demand: this call is the only
    /// signal here for where in the book the patron is, and a chapter whose
    /// length is unknown pays Readium's probe, measured at 18.6 MB to deliver
    /// two bytes. `storedPlaintextLength` is the same read without the record,
    /// for this object's own filtering.
    nonisolated public func cachedPlaintextLength(forHref href: String) -> UInt64? {
        guard let length = storedPlaintextLength(forHref: href) else {
            demandedTracks.record(href)
            return nil
        }
        return length
    }

    nonisolated private func storedPlaintextLength(forHref href: String) -> UInt64? {
        guard let prefix = plaintextLengthKeyPrefix else { return nil }
        let stored = UserDefaults.standard.object(forKey: prefix + href) as? NSNumber
        guard let value = stored?.uint64Value, value > 0 else { return nil }
        return value
    }

    nonisolated public func cachePlaintextLength(_ length: UInt64, forHref href: String) {
        guard length > 0, let prefix = plaintextLengthKeyPrefix else { return }
        UserDefaults.standard.set(NSNumber(value: length), forKey: prefix + href)
        demandedTracks.resolved(href)
    }

    /// The length a chapter needs, waiting for the resolution already running
    /// rather than letting Readium read the entry's CBC tail.
    ///
    /// Which answer applies is decided here, not by the caller: the length is
    /// already known; nothing is running, so none is coming; the resolution
    /// reaches this track and reports it; or it ends, or the wait runs out,
    /// without it. Only the first and third spare the chapter the probe, which
    /// was measured at 18.6 MB of origin traffic to deliver two bytes.
    nonisolated public func plaintextLength(
        forHref href: String,
        waitingUpTo timeout: TimeInterval
    ) async -> UInt64? {
        // Through the recording read: this ask is what puts the track at the
        // head of the resolution's queue.
        if let known = cachedPlaintextLength(forHref: href) { return known }
        guard trackLengthResolutions.isRunning else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Polled rather than signalled. The resolution reports a length by
            // storing it, and a waiter registry would have to stay correct
            // against cancellation, teardown, and a resolution that ends
            // without this track — four more states on the chapter-change
            // path. The interval costs at most itself, inside a wait the
            // chapter is already in.
            do {
                try await Task.sleep(nanoseconds: Self.trackLengthPollInterval)
            } catch {
                return nil // this chapter was dropped while waiting
            }
            if let learned = storedPlaintextLength(forHref: href) { return learned }
            // The resolution has ended without this track, so nothing further
            // is coming and waiting out the timeout would only delay the probe.
            guard trackLengthResolutions.isRunning else { return nil }
        }
        return nil
    }

    static let trackLengthPollInterval: UInt64 = 100_000_000

    /// Learns and remembers the plaintext length of every named track that has
    /// none yet, reading the archive directly instead of through Readium's
    /// buffered probe.
    ///
    /// The archive reads are injected so a test drives this without a network.
    /// `LCPArchiveTrackLengthResolver` decides which bytes to read.
    /// Returns what the resolution did, which is what the caller reports.
    nonisolated func resolveTrackLengths(
        hrefs: [String],
        archiveLength: UInt64,
        maxConcurrentReads: Int = LCPArchiveTrackLengthResolver.defaultMaxConcurrentReads,
        readRange: @escaping LCPArchiveTrackLengthResolver.ReadRange,
        decipher: @escaping LCPArchiveTrackLengthResolver.Decipher
    ) async -> LCPArchiveTrackLengthResolver.Summary {
        let missing = hrefs.filter { storedPlaintextLength(forHref: $0) == nil }
        guard !missing.isEmpty else { return .init() }

        trackLengthResolutions.enter()
        defer { trackLengthResolutions.leave() }

        return await LCPArchiveTrackLengthResolver(
            archiveLength: archiveLength,
            readRange: readRange,
            decipher: decipher
        )
        .resolveLengths(
            forHrefs: missing,
            maxConcurrentReads: maxConcurrentReads,
            nextDemanded: { self.demandedTracks.first }
        ) { href, length in
            self.cachePlaintextLength(length, forHref: href)
        }
    }

    /// The reading-order hrefs with no length yet, keyed as the player will ask
    /// for them: the fragment dropped, the order kept.
    ///
    /// `known` is passed in rather than read here so a test states the
    /// selection without a length store, and so the caller decides whether an
    /// ask counts as a chapter waiting.
    nonisolated static func unresolvedTrackHrefs(
        in publication: Publication,
        known: (String) -> UInt64?
    ) -> [String] {
        publication.readingOrder
            .map { link in link.href.components(separatedBy: "#").first ?? link.href }
            .filter { known($0) == nil }
    }

    /// Starts learning this archive's track lengths in the background.
    ///
    /// Streaming only: a local package is read from disk, where the probe costs
    /// a file read rather than a 6 MB window. The work runs off the open so the
    /// first chapter starts while the rest of the book's lengths fill in, and
    /// it is cancelled with the instance.
    private func startResolvingTrackLengths(for publication: Publication) {
        guard let licenseUrl else {
            // Silence here is indistinguishable in a device log from a
            // resolution that ran and found nothing, so say which it was.
            Log.error(#file, "LCP track lengths: opened from a local package, so no track length is read from the origin")
            return
        }
        guard let archiveURL = Self.publicationURL(inLicenseAt: licenseUrl) else {
            Log.error(#file, "LCP track lengths: the licence names no publication URL; every chapter keeps the probe")
            return
        }
        // At `.error` like the open's own line: only error and fault reach the
        // log a patron can export, and a resolution that never starts is
        // indistinguishable in that log from one that found nothing to do.
        guard let license = publication.lcpLicense else {
            Log.error(#file, "LCP track lengths: no open licence on the publication; every chapter keeps the probe")
            return
        }

        // Read before the task: the hrefs the player will ask the cache with
        // are the reading-order hrefs, minus any fragment, exactly as
        // `LCPResourceLoaderDelegate` keys them.
        //
        // Asked here as well as inside `resolveTrackLengths` so that a book
        // whose lengths are all known from an earlier session costs not even
        // the HEAD that locates the archive's tail.
        let hrefs = Self.unresolvedTrackHrefs(in: publication) {
            self.storedPlaintextLength(forHref: $0)
        }
        guard !hrefs.isEmpty else {
            Log.error(#file, "LCP track lengths: all \(publication.readingOrder.count) track length(s) already known")
            return
        }

        let client = archiveReadClient
        // Announced before the task runs, not inside it: the archive's length
        // is a request of its own, and a chapter asking in that gap would
        // otherwise be told nothing is coming and go to the probe.
        trackLengthResolutions.enter()
        let task = Task { [weak self] in
            defer { self?.trackLengthResolutions.leave() }
            guard let self, !self.isReleasedSnapshot() else { return }
            let startedAt = Date()
            guard let archiveLength = await Self.archiveLength(of: archiveURL, using: client) else {
                Log.error(#file, "LCP track lengths: the archive reported no length; every chapter keeps the probe")
                return
            }
            let summary = await self.resolveTrackLengths(
                hrefs: hrefs,
                archiveLength: archiveLength,
                readRange: { await Self.readArchiveRange($0, of: archiveURL, using: client) },
                decipher: { try? license.decipher($0) }
            )
            // The resolution's own reads, counted inside it. The archive
            // client's counter is shared with playback and would attribute the
            // loader's 6 MB windows to this work.
            Log.error(#file, String(
                format: "LCP track lengths: resolved %d of %d track(s) in %.1fs; this resolution read %d range(s) for %d bytes",
                summary.resolved,
                hrefs.count,
                Date().timeIntervalSince(startedAt),
                summary.requests,
                summary.bytes
            ))
        }
        publicationCacheQueue.async {
            self.trackLengthTask?.cancel()
            self.trackLengthTask = task
        }
    }

    /// The archive's length, from a HEAD. One request per open, and the only
    /// way to know where the tail that holds the central directory begins.
    ///
    /// Internal rather than private: what the server has to say for a length to
    /// be believed is pinned by a test.
    static func archiveLength(of url: HTTPURL, using client: HTTPClient) async -> UInt64? {
        let response = try? await client.fetch(HTTPRequest(url: url, method: .head)).get()
        // `contentLength` is signed, and a server may answer with no length at
        // all; neither shape names a tail to read.
        guard let length = response?.contentLength, length > 0 else { return nil }
        return UInt64(length)
    }

    /// One bounded range of the archive. Bounded on purpose: an open-ended
    /// `bytes=start-` resolves to the whole 715 MB object.
    ///
    /// Internal rather than private: a `Range` is half-open and the header is
    /// inclusive, and that conversion is pinned by a test — asking one byte
    /// short of the entry's end deciphers the wrong block.
    static func readArchiveRange(
        _ range: Range<UInt64>, of url: HTTPURL, using client: HTTPClient
    ) async -> Data? {
        guard !range.isEmpty else { return nil }
        let request = HTTPRequest(
            url: url,
            method: .get,
            headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"]
        )
        return try? await client.fetch(request).get().body
    }

    /// The archive client's origin cost, for the loader's slow-chapter line.
    /// Read off the same counting client this type opens the publication with.
    nonisolated public func archiveOriginActivity() -> (requests: Int, bytes: Int) {
        let activity = archiveReadClient.upstreamActivity
        return (requests: activity.originRequests, bytes: activity.originBytes)
    }

    nonisolated public func archiveIsLocalFile() -> Bool {
        return licenseUrl == nil
    }

    /// The link-yielding pair is bound, and deliberately does nothing yet.
    ///
    /// The toolkit announces the start and end of a load the patron is waiting
    /// on so a provider can hold its background package fetch and let that
    /// chapter have the link (PP-5367). This hotfix does not hold the fetch.
    ///
    /// Suspending the transfer here was implemented and withdrawn. A hold needs
    /// somewhere to record the task it suspended, and one process-wide slot is
    /// not enough: registering a second transfer, finishing one, or resuming
    /// one from partial data all replaced that slot, leaving the suspended task
    /// with nothing holding a reference that could resume it. The patron saw a
    /// download stop at the byte it had reached. A correct hold keys the
    /// suspension per transfer and expires on a timer rather than on a
    /// callback that may never arrive.
    ///
    /// The competitor worth removing is larger than this one anyway: the
    /// playback model prefetched whole tracks over the same link, three at a
    /// time, and now defers that until the archive is local. The load timeout
    /// is decided from bytes served and elapsed time inside the player, so it
    /// does not depend on either hook.
    ///
    /// Written out rather than defaulted: the protocol gives this pair no
    /// default, so a conformer that stops binding them fails to compile rather
    /// than losing the behaviour with no diagnostic once it is wired up.
    nonisolated public func streamingLoadDidBegin() {}

    nonisolated public func streamingLoadDidEnd() {}

    /// Nonisolated on purpose — see the note on the extension. This is a
    /// nonisolated witness of a `@MainActor` protocol requirement, which Swift
    /// allows because it is the permissive direction.
    ///
    /// It still runs on the main actor in practice, and the `assumeIsolated`
    /// below depends on that. Two independent guarantees, not one:
    ///   - the protocol requirement is `@MainActor`
    ///     (`StreamingResourceProvider.swift`), so every protocol-dispatched
    ///     caller is already there — compiler-enforced;
    ///   - the sole PRODUCTION call site is `Audiobook.swift`'s
    ///     `DynamicPlayerFactory.createPlayer`, itself `@MainActor`.
    ///
    /// Nothing enforces this for a *direct* Swift call on the concrete type, so
    /// that would trap. Objective-C cannot reach it: extension members get no
    /// implicit `@objc`, and this witnesses a plain Swift protocol.
    public func setupStreamingFor(_ player: Any) -> Bool {
        guard let streamingPlayer = player as? StreamingCapablePlayer else {
            return false
        }
        if isReleasedSnapshot() {
            return false
        }
        // `setStreamingProvider` is main-actor state on the player, but this
        // conformance CANNOT be isolated: `LCPStreamingProvider` inherits
        // `DRMDecryptor`, and isolating the conformance isolates that too —
        // "main actor-isolated conformance ... cannot be used in nonisolated
        // context", because decryption legitimately runs off-main.
        //
        // `assumeIsolated` is sound here rather than hopeful: the only call path
        // is `AudiobookLoader` (@MainActor) -> finalizeBuild -> Audiobook.init ->
        // DynamicPlayerFactory.createPlayer (@MainActor) -> here.
        MainActor.assumeIsolated {
            streamingPlayer.setStreamingProvider(self)
        }

        let hasPublication = publicationCacheQueue.sync {
            return cachedPublication != nil
        }

        if hasPublication {
            // Publication is already loaded (the loader's contentDictionary call
            // cached it). Signal the player right away so it doesn't wait on the
            // 30s "Publication loading timeout" fallback. Without this, every
            // back-to-back LCP audiobook open creates a fresh LCPStreamingPlayer
            // whose isLoaded flag can only flip via publicationDidLoad() — which
            // otherwise only fires from the !hasPublication branch below.
            DispatchQueue.main.async {
                streamingPlayer.publicationDidLoad()
            }
        } else {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.loadContentDictionary { _, error in
                    if let error = error {
                        Log.error(#file, "Failed to load LCP publication for streaming: \(error)")
                    } else {
                        Log.info(#file, "Successfully loaded LCP publication for streaming")

                        DispatchQueue.main.async {
                            streamingPlayer.publicationDidLoad()
                        }
                    }
                }
            }
        }

        return true
    }

}

// MARK: - Cached manifest access
extension LCPAudiobooks {
    /// Returns the cached content dictionary if the publication has already been opened.
    /// This avoids re-opening the asset and enables immediate UI presentation.
    public func cachedContentDictionary() -> NSDictionary? {
        let publication = publicationCacheQueue.sync {
            return cachedPublication
        }

        guard let publication, let jsonManifestString = publication.jsonManifest,
              let jsonData = jsonManifestString.data(using: .utf8) else {
            return nil
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
            return jsonObject
        }
        return nil
    }

    public func startPrefetch() {
        if isReleasedSnapshot() { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.loadContentDictionary { _, _ in
            }
        }
    }

    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
        if isReleasedSnapshot() {
            completion(Self.releasedError())
            return
        }
        if let publication = getPublication() {
            Self.decryptWithPublication(publication, url: url, to: resultUrl, completion: completion)
            return
        }
        // No cached publication means this decryptor's session has ended (either never
        // opened, or released). Do NOT reopen through publicationOpener — that raced
        // the next session's open on the same .lcpa and deadlocked Readium.
        completion(Self.releasedError())
    }

    static func decryptWithPublication(_ publication: Publication, url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
        if let resource = publication.getResource(at: url.path) {
            // The completion originates from the toolkit's `@objc public
            // protocol DRMDecryptor` (off-limits submodule), so its parameter
            // type cannot be annotated `@Sendable`. We must still hand it to a
            // `DispatchQueue.main.async` closure (a strictly-`@Sendable`
            // boundary) to deliver the result on main. Wrap it once, before
            // entering the `Task`, so the `@Sendable` closures capture the
            // Sendable box rather than the bare non-Sendable closure.
            let completionBox = SendableDecryptCompletion(completion)
            Task {
                do {
                    try await LCPTrackFileWriter.write(resource, to: resultUrl)
                    DispatchQueue.main.async {
                        completionBox.fire(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        completionBox.fire(error)
                    }
                }
            }
        } else {
            completion(NSError(domain: "AudiobookResourceError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Resource not found at path: \(url.path)"]))
        }
    }

    public func cancelPrefetch() {
        publicationCacheQueue.sync {
            currentPrefetchTask?.cancel()
            currentPrefetchTask = nil
        }
    }

    /// Release all held resources and mark the instance as a dead one-shot.
    /// After this call, decrypt/contentDictionary/startPrefetch/setupStreamingFor
    /// all fail fast. Idempotent.
    public func releaseResources() {
        publicationCacheQueue.sync {
            isReleased = true
            currentPrefetchTask?.cancel()
            currentPrefetchTask = nil
            trackLengthTask?.cancel()
            trackLengthTask = nil
            cachedPublication = nil
        }
    }
}

private extension Publication {
    func getResource(at path: String) -> Resource? {
        let resource = get(Link(href: path))
        guard type(of: resource) != FailureResource.self else {
            return get(Link(href: "/" + path))
        }

        return resource
    }
}

/// Writes a decrypted LCP track to disk without holding the whole track in
/// memory (PP-5347: a full `read()` of a long track ran 3.3.1 out of memory).
///
/// The track is streamed into a hidden sibling file and moved into place only
/// once complete, because the toolkit treats any file at the destination as an
/// already-decrypted track.
enum LCPTrackFileWriter {
    static let defaultChunkSize: UInt64 = 1024 * 1024

    static func write(
        _ resource: Resource,
        to destination: URL,
        chunkSize: UInt64 = defaultChunkSize,
        fileManager: FileManager = .default
    ) async throws {
        // Readium's CBC resource refuses ranged reads when it cannot compute the
        // plaintext length, but still decrypts a whole read. Keep that path.
        guard case .success(.some) = await resource.estimatedLength() else {
            let data = try await resource.read().get()
            try data.write(to: destination, options: .atomic)
            return
        }

        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }

        do {
            let handle = try FileHandle(forWritingTo: partial)
            do {
                var offset: UInt64 = 0
                while true {
                    let chunk = try await resource.read(range: offset ..< offset + chunkSize).get()
                    try handle.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                    // Readium clamps ranges to the resource length, so a short read is the end.
                    if UInt64(chunk.count) < chunkSize { break }
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            // rename(2) replaces an existing destination atomically, so a concurrent
            // decrypt of the same track cannot fail on "file exists".
            guard rename(partial.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }
}

/// `Sendable` wrapper for a `DRMDecryptor.decrypt` completion closure.
///
/// The toolkit's `@objc public protocol DRMDecryptor` (in the off-limits
/// `PalaceAudiobookToolkit` submodule) types the completion as a plain
/// `(Error?) -> Void`, so it cannot be annotated `@Sendable` at the
/// conformance site without diverging from the `@objc` requirement. This box
/// lets the completion cross into the decrypt `Task`'s `DispatchQueue.main.async`
/// hop (a strictly-`@Sendable` boundary) without a concurrency warning.
///
/// - Sendable invariant: `fire(_:)` forwards to the wrapped closure exactly
///   once, always from a single `DispatchQueue.main.async` continuation in
///   `decryptWithPublication` (success XOR failure) — never concurrently from
///   two threads. The wrapped closure is otherwise opaque, hence `@unchecked`.
private struct SendableDecryptCompletion: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func fire(_ error: Error?) {
        completion(error)
    }
}

/// `Sendable` carrier for the `(NSDictionary?, NSError?)` result of
/// `loadContentDictionary`, used to cross the single `DispatchQueue.main.async`
/// hop in `contentDictionary` without a `sending` diagnostic.
///
/// `NSDictionary` (the parsed LCP manifest) and `NSError` are `@objc` reference
/// types the compiler does not treat as `Sendable`. Both are produced fresh by
/// the load and only read once on the main thread, so boxing them makes the
/// hand-off explicit rather than sending bare non-Sendable references.
///
/// - Sendable invariant: `json` / `error` are set once at init and only read
///   thereafter — neither the manifest dictionary nor the error is mutated
///   after boxing, so there is no shared mutation. The `@unchecked` waiver
///   covers only the un-audited `@objc` payload types.
private struct LCPContentResultBox: @unchecked Sendable {
    let json: NSDictionary?
    let error: NSError?
}

/// How many pieces of work of one kind are in flight.
///
/// - Sendable invariant: every access goes through `lock`.
private final class WorkInFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var isRunning: Bool { lock.withLock { count > 0 } }

    func enter() { lock.withLock { count += 1 } }

    /// Never below zero: a leave without an enter would otherwise make a later
    /// enter read as not running.
    func leave() { lock.withLock { count = max(0, count - 1) } }
}

/// The tracks a chapter load has asked the length cache for and not found.
///
/// Holds its own lock rather than using the publication cache queue: the ask
/// happens on the chapter-change path, from whatever thread AVFoundation hands
/// the loader, and that queue also serialises the publication open.
///
/// - Sendable invariant: every access goes through `lock`.
private final class DemandedTracks: @unchecked Sendable {
    /// A player builds seven items at a time, so a longer queue would only
    /// hold tracks nobody is waiting for.
    private static let capacity = 8

    private let lock = NSLock()
    private var hrefs: [String] = []

    /// The oldest ask still outstanding.
    var first: String? { lock.withLock { hrefs.first } }

    func record(_ href: String) {
        lock.withLock {
            guard !hrefs.contains(href) else { return }
            hrefs = Array((hrefs + [href]).suffix(Self.capacity))
        }
    }

    func resolved(_ href: String) {
        lock.withLock { hrefs.removeAll { $0 == href } }
    }
}

#endif
