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

    override func tearDownWithError() throws {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
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
