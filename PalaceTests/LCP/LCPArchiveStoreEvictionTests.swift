//
//  LCPArchiveStoreEvictionTests.swift
//  PalaceTests
//
//  Eviction of retained LCP archive range stores: which directories it may
//  unlink and which it must leave alone.
//

#if LCP

import XCTest
import PalaceAudiobookToolkit
import ReadiumShared
@testable import Palace

/// `removeItem` ignores the `flock` a `PartialArchiveStore` holds, so unlinking
/// a directory whose store is open leaves that store writing and fsyncing into
/// an inode no path reaches. Reads keep answering, so nothing surfaces as an
/// error — every window it caches is discarded and refetched from the origin.
final class LCPArchiveStoreEvictionTests: XCTestCase {

    /// Matches `PartialArchiveStore.lockFileName`, which is internal to the
    /// toolkit module and so cannot be referenced from here.
    private static let lockFileName = "archive.lock"

    private var createdDirectories: [URL] = []
    private var licenseFiles: [URL] = []

    override func tearDownWithError() throws {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
        for file in licenseFiles {
            try? FileManager.default.removeItem(at: file)
        }
        licenseFiles = []
        try super.tearDownWithError()
    }

    /// A directory under the root the production code actually reads, so this
    /// exercises `partialArchivesRoot` rather than a stand-in. The name is
    /// unique per call, so one test cannot be handed another's directory.
    private func makeStoreDirectory() throws -> URL {
        let root = try LCPAudiobooks.partialArchivesRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("evict-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    /// A name no directory on disk carries, so every entry in the root is a
    /// candidate for eviction and the assertions are about the holder alone.
    private func absentKeepName() throws -> URL {
        try LCPAudiobooks.partialArchivesRoot()
            .appendingPathComponent("keep-\(UUID().uuidString)", isDirectory: true)
    }

    private func lockFileExists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Self.lockFileName).path
        )
    }

    func testEvictArchiveStores_whenAnOpenStoreHoldsTheDirectory_leavesItInPlace() throws {
        let held = try makeStoreDirectory()
        let stale = try makeStoreDirectory()

        let store = try PartialArchiveStore.open(directory: held, totalSize: 4096)
        defer { store.close() }

        XCTAssertTrue(
            lockFileExists(in: held),
            "precondition: the open store must have written the lock file the eviction probes"
        )
        XCTAssertFalse(
            lockFileExists(in: stale),
            "precondition: the unheld directory must have no lock file"
        )

        LCPAudiobooks.evictArchiveStoresOtherThan(try absentKeepName())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale.path),
            "a directory no store holds must still be evicted, or the disk grows without bound"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: held.path),
            "unlinking a directory whose store is open leaves that store writing into an unlinked inode, so every window it caches is thrown away"
        )
    }

    // MARK: - Scoped removal when one archive lands whole

    /// Writes a licence whose `publication` link is `href`, in the shape the
    /// server sends: `links` is an array and `rel` is a single string.
    private func makeLicense(publicationHref href: String?) throws -> URL {
        var links: [[String: Any]] = [
            ["rel": "hint", "type": "text/html", "href": "https://example.org/lcp/hint"]
        ]
        if let href {
            links.append(["rel": "publication", "type": "application/audiobook+lcp", "href": href])
        }
        let license: [String: Any] = ["id": UUID().uuidString, "provider": "https://example.org", "links": links]
        let data = try JSONSerialization.data(withJSONObject: license)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("license-\(UUID().uuidString).lcpl")
        try data.write(to: url)
        licenseFiles.append(url)
        return url
    }

    private func storeDirectory(forPublication href: String) throws -> URL {
        let url = try XCTUnwrap(HTTPURL(string: href), "the fixture href must be an HTTP URL")
        let directory = try LCPAudiobooks.archiveStoreDirectory(for: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    func testRemoveArchiveStore_leavesTheStoreOfAnArchiveTheLicenceDoesNotName() throws {
        let landed = "https://storage.googleapis.com/bucket/landed-\(UUID().uuidString)"
        let streaming = "https://storage.googleapis.com/bucket/streaming-\(UUID().uuidString)"
        let landedStore = try storeDirectory(forPublication: landed)
        let streamingStore = try storeDirectory(forPublication: streaming)

        LCPAudiobooks.removeArchiveStore(forLicenseAt: try makeLicense(publicationHref: landed))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: landedStore.path),
            "the ranges of an archive now stored whole are a second copy of the same audio and must be reclaimed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: streamingStore.path),
            "a whole-archive transfer finishing for one book must not discard the cache the book being streamed serves its next chapter from"
        )
    }

    func testRemoveArchiveStore_whenAnOpenStoreHoldsTheDirectory_leavesItInPlace() throws {
        let href = "https://storage.googleapis.com/bucket/held-\(UUID().uuidString)"
        let directory = try storeDirectory(forPublication: href)

        let store = try PartialArchiveStore.open(directory: directory, totalSize: 4096)
        defer { store.close() }

        LCPAudiobooks.removeArchiveStore(forLicenseAt: try makeLicense(publicationHref: href))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "removeItem ignores the flock, so unlinking a held directory leaves its reader writing into an inode no path reaches"
        )
    }

    func testRemoveArchiveStore_whenTheLicenceNamesNoPublication_removesNothing() throws {
        let other = "https://storage.googleapis.com/bucket/other-\(UUID().uuidString)"
        let otherStore = try storeDirectory(forPublication: other)

        LCPAudiobooks.removeArchiveStore(forLicenseAt: try makeLicense(publicationHref: nil))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: otherStore.path),
            "a licence this build cannot read an archive URL from must not escalate to clearing every store"
        )
    }

    func testRemoveArchiveStore_whenTheLicenceIsUnreadable_removesNothing() throws {
        let other = "https://storage.googleapis.com/bucket/other-\(UUID().uuidString)"
        let otherStore = try storeDirectory(forPublication: other)
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).lcpl")

        LCPAudiobooks.removeArchiveStore(forLicenseAt: absent)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: otherStore.path),
            "a missing licence leaves the archive URL unknown, and an unknown key must remove nothing"
        )
    }

    /// A publication link that is not an HTTP URL cannot key a store, and the
    /// archive it names is not one this path fetched. Nothing may be removed on
    /// its account.
    func testRemoveArchiveStore_whenThePublicationIsNotAnHTTPURL_removesNothing() throws {
        let other = "https://storage.googleapis.com/bucket/other-\(UUID().uuidString)"
        let otherStore = try storeDirectory(forPublication: other)

        LCPAudiobooks.removeArchiveStore(
            forLicenseAt: try makeLicense(publicationHref: "file:///var/mobile/archive.lcpa")
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: otherStore.path),
            "a publication href that is not an HTTP URL keys no store, so it must not stand in for one"
        )
    }

    /// The LCP schema admits `rel` as an array as well as a string. Reading only
    /// the string form would leave a conforming licence's store behind forever.
    func testPublicationURL_whenRelIsAnArray_readsTheArchiveURL() throws {
        let href = "https://storage.googleapis.com/bucket/array-rel"
        let license: [String: Any] = [
            "id": UUID().uuidString,
            "links": [["rel": ["publication", "alternate"], "href": href]]
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("license-\(UUID().uuidString).lcpl")
        try JSONSerialization.data(withJSONObject: license).write(to: url)
        licenseFiles.append(url)

        XCTAssertEqual(
            LCPAudiobooks.publicationURL(inLicenseAt: url)?.string,
            href,
            "a licence spelling rel as an array still names its publication"
        )
    }

    func testEvictArchiveStores_afterTheHoldingStoreCloses_removesTheDirectory() throws {
        let directory = try makeStoreDirectory()

        let store = try PartialArchiveStore.open(directory: directory, totalSize: 4096)
        store.close()

        XCTAssertTrue(
            lockFileExists(in: directory),
            "precondition: the lock file outlives the store, so presence alone cannot stand in for a holder"
        )

        LCPAudiobooks.evictArchiveStoresOtherThan(try absentKeepName())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "a closed store holds nothing, so its directory is stale and must be evicted"
        )
    }
}

#endif
