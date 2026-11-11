//
//  LCPAudiobooks+PartialArchiveStore.swift
//  The Palace Project
//
//  Where a streamed archive's byte ranges are kept on disk, and how they are
//  found, evicted and removed.
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
        removeArchiveStore(forPublicationAt: publicationURL)
    }

    /// The same removal for a licence that is not on disk as a file, such as
    /// the one embedded in a package.
    static func removeArchiveStore(forPublicationAt publicationURL: HTTPURL) {
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

#endif
