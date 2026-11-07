//  GeneralCacheDiskWriteTests.swift
//
//  Disk writes run outside the cache lock, so a slow write does not hold up
//  reads of other keys, and a remove or a newer set during the write still
//  wins (PP-5499).

import XCTest
@testable import Palace

final class GeneralCacheDiskWriteTests: XCTestCase {

    private var cache: GeneralCache<String, Data>?
    private var gate: WriteGate!

    override func setUp() {
        super.setUp()
        gate = WriteGate()
        let gate = gate!
        cache = GeneralCache<String, Data>(
            cacheName: "GeneralCacheDiskWrite-\(UUID().uuidString)",
            mode: .memoryAndDisk,
            writeData: { data, url in
                gate.enterAndWait(for: data)
                try data.write(to: url, options: .atomic)
            }
        )
    }

    override func tearDown() {
        gate.openAll()
        cache?.clear()
        cache = nil
        super.tearDown()
    }

    /// A read of another key returns while a write is still in progress.
    func testGet_whileAnotherKeyIsBeingWritten_doesNotWaitForTheWrite() throws {
        let cache = try XCTUnwrap(cache)
        cache.set(Data("ready".utf8), for: "ready", expiresIn: 3600)
        cache.clearMemory()
        let slow = Data("slow".utf8)
        gate.hold(slow)

        let writer = Thread { cache.set(slow, for: "slow", expiresIn: 3600) }
        writer.start()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 10))

        let readReturned = expectation(description: "read returns during the write")
        DispatchQueue.global().async {
            _ = cache.get(for: "ready")
            readReturned.fulfill()
        }
        wait(for: [readReturned], timeout: 5) // STARVE-001-OK: a read stuck behind the write never returns, so detecting it needs a bound
        gate.openAll()
    }

    /// A remove that lands while the write is in progress is not undone when
    /// the write finishes.
    func testRemove_duringAnInProgressWrite_leavesNoFile() throws {
        let cache = try XCTUnwrap(cache)
        let slow = Data("slow".utf8)
        gate.hold(slow)
        let writeDone = expectation(description: "set returns")
        DispatchQueue.global().async {
            cache.set(slow, for: "key", expiresIn: 3600)
            writeDone.fulfill()
        }
        XCTAssertTrue(gate.waitUntilEntered(timeout: 10))

        let removed = expectation(description: "remove returns while the write is held")
        DispatchQueue.global().async {
            cache.remove(for: "key")
            removed.fulfill()
        }
        wait(for: [removed], timeout: 5) // STARVE-001-OK: a remove stuck behind the write never returns, so detecting it needs a bound
        gate.openAll()
        wait(for: [writeDone], timeout: 10) // STARVE-001-OK: bounded join on a background write

        cache.clearMemory()
        XCTAssertNil(cache.get(for: "key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(for: "key").path))
        let directory = cache.fileURL(for: "key").deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".staged-") }, [], "an unpublished staging file must be deleted")
    }

    /// When an older write finishes after a newer one, the newer value stays.
    func testSet_olderWriteFinishingLast_keepsTheNewerValue() throws {
        let cache = try XCTUnwrap(cache)
        let older = Data("older".utf8)
        let newer = Data("newer".utf8)
        gate.hold(older)
        let olderDone = expectation(description: "older set returns")
        DispatchQueue.global().async {
            cache.set(older, for: "key", expiresIn: 3600)
            olderDone.fulfill()
        }
        XCTAssertTrue(gate.waitUntilEntered(timeout: 10))

        let newerSet = expectation(description: "newer set returns while the older write is held")
        DispatchQueue.global().async {
            cache.set(newer, for: "key", expiresIn: 3600)
            newerSet.fulfill()
        }
        wait(for: [newerSet], timeout: 5) // STARVE-001-OK: a set stuck behind the write never returns, so detecting it needs a bound
        gate.openAll()
        wait(for: [olderDone], timeout: 10) // STARVE-001-OK: bounded join on a background write

        cache.clearMemory()
        XCTAssertEqual(cache.get(for: "key"), newer)
    }

    /// Several keys for one value are one write; the other keys name the same file.
    func testSetForKeys_writesOnceAndLinksTheOtherKeys() throws {
        let cache = try XCTUnwrap(cache)
        let payload = Data("cover".utf8)

        cache.set(payload, for: ["a", "b", "c"], expiresIn: 3600)

        XCTAssertEqual(gate.writeCount, 1)
        cache.clearMemory()
        XCTAssertEqual(cache.get(for: "b"), payload)
        let numbers = try ["a", "b", "c"].map { key -> Int in
            let attributes = try FileManager.default.attributesOfItem(atPath: cache.fileURL(for: key).path)
            return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
        }
        XCTAssertEqual(Set(numbers).count, 1)
    }

    func testRemove_oneAlias_leavesTheOtherKeysReadable() throws {
        let cache = try XCTUnwrap(cache)
        let payload = Data("cover".utf8)
        cache.set(payload, for: ["a", "b"], expiresIn: 3600)

        cache.remove(for: "a")
        cache.clearMemory()

        XCTAssertNil(cache.get(for: "a"))
        XCTAssertEqual(cache.get(for: "b"), payload)
    }

    func testHasUnexpiredDiskEntry_reflectsWrittenExpiredAndMissingKeys() throws {
        let cache = try XCTUnwrap(cache)
        cache.set(Data("fresh".utf8), for: "fresh", expiresIn: 3600)
        cache.set(Data("stale".utf8), for: "stale", expiresIn: -60)

        XCTAssertTrue(cache.hasUnexpiredDiskEntry(for: "fresh"))
        XCTAssertFalse(cache.hasUnexpiredDiskEntry(for: "stale"))
        XCTAssertFalse(cache.hasUnexpiredDiskEntry(for: "missing"))
    }

    /// A key whose write is still in progress counts as on disk, so a second
    /// store does not encode and write it again.
    func testHasUnexpiredDiskEntry_whileTheWriteIsInProgress_isTrue() throws {
        let cache = try XCTUnwrap(cache)
        let slow = Data("slow".utf8)
        gate.hold(slow)
        let writeDone = expectation(description: "set returns")
        DispatchQueue.global().async {
            cache.set(slow, for: "key", expiresIn: 3600)
            writeDone.fulfill()
        }
        XCTAssertTrue(gate.waitUntilEntered(timeout: 10))

        let inProgress = cache.hasUnexpiredDiskEntry(for: "key")
        gate.openAll()
        wait(for: [writeDone], timeout: 10) // STARVE-001-OK: bounded join on a background write

        XCTAssertTrue(inProgress)
    }

    func testHasUnexpiredDiskEntry_byMode() {
        let diskOnly = GeneralCache<String, Data>(cacheName: "GeneralCacheDiskOnly-\(UUID().uuidString)", mode: .diskOnly)
        let memoryOnly = GeneralCache<String, Data>(cacheName: "GeneralCacheMemoryOnly-\(UUID().uuidString)", mode: .memoryOnly)
        defer {
            diskOnly.clear()
            memoryOnly.clear()
        }

        diskOnly.set(Data("d".utf8), for: "key", expiresIn: 3600)
        memoryOnly.set(Data("m".utf8), for: "key", expiresIn: 3600)

        XCTAssertTrue(diskOnly.hasUnexpiredDiskEntry(for: "key"))
        XCTAssertFalse(memoryOnly.hasUnexpiredDiskEntry(for: "key"), "a memory-only cache has nothing on disk")
    }
}

/// Holds chosen writes open until the test releases them, and counts writes.
private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<Data> = []
    private var writes = 0
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var released = false

    var writeCount: Int { lock.withLock { writes } }

    func hold(_ data: Data) { lock.withLock { _ = held.insert(data) } }

    func enterAndWait(for data: Data) {
        let shouldHold = lock.withLock { () -> Bool in
            writes += 1
            return held.contains(data) && !released
        }
        guard shouldHold else { return }
        entered.signal()
        release.wait()
    }

    func waitUntilEntered(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func openAll() {
        let wasReleased = lock.withLock { () -> Bool in
            let was = released
            released = true
            return was
        }
        guard !wasReleased else { return }
        for _ in 0..<8 { release.signal() }
    }
}
