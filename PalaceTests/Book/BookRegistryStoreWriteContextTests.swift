//
//  BookRegistryStoreWriteContextTests.swift
//  PalaceTests
//
//  PP-5274: a synchronous write may run inline only inside a write of the same
//  store. Started inside a read, it would run while other reads continue, so
//  the store reports it and skips the write instead.
//

import XCTest
@testable import Palace
import PalaceBookModel
@testable import PalaceBookRegistry

final class BookRegistryStoreWriteContextTests: XCTestCase {

    private var recorder: WriteInsideReadRecorder!
    private var store: BookRegistryStore!

    override func setUp() {
        super.setUp()
        recorder = WriteInsideReadRecorder()
        store = makeStore(recorder: recorder)
    }

    override func tearDown() {
        store = nil
        recorder = nil
        super.tearDown()
    }

    private func makeStore(recorder: WriteInsideReadRecorder) -> BookRegistryStore {
        BookRegistryStore(onWriteInsideRead: { recorder.record($0) })
    }

    private func makeBook(identifier: String = "book-1", authors: [String] = ["Author"]) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: authors.map { TPPBookAuthor(authorName: $0, relatedBooksURL: nil) },
            categoryStrings: ["Fiction"], distributor: nil,
            identifier: identifier, imageURL: nil, imageThumbnailURL: nil,
            published: nil, publisher: nil, subtitle: nil, summary: nil,
            title: "Title \(identifier)", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func seed(_ identifiers: String..., state: TPPBookState = .downloadNeeded) async {
        for identifier in identifiers {
            store.addBook(makeBook(identifier: identifier), state: state)
        }
        await store._awaitPendingWritesForTesting()
    }

    // MARK: - A write started inside a read is reported and skipped

    /// The loans record must not change from inside a read, where other reads run alongside it.
    func testMutateRegistrySync_InsideRead_ReportsAndLeavesRegistryUnchanged() async {
        await seed("book-1")
        var onCompleteRan = false

        store.readRegistry { _ in
            store.mutateRegistrySync({ $0["book-1"]?.state = .downloadSuccessful },
                                     onComplete: { onCompleteRan = true })
        }

        XCTAssertEqual(recorder.operations, ["mutateRegistrySync"])
        XCTAssertEqual(store.state(for: "book-1"), .downloadNeeded)
        XCTAssertFalse(onCompleteRan, "onComplete follows a write that did not happen")
    }

    func testPerformBarrierSync_InsideQueryRead_ReportsAndDoesNotRunBlock() {
        var blockRan = false

        let didRun = store.performSync { store.performBarrierSync { blockRan = true } }

        XCTAssertFalse(didRun)
        XCTAssertFalse(blockRan)
        XCTAssertEqual(recorder.operations, ["performBarrierSync"])
    }

    func testUpdatedBookMetadata_InsideRead_ReportsAndReturnsNil() async {
        await seed("book-1")

        let merged = store.readRegistry { _ in
            store.updatedBookMetadata(makeBook(identifier: "book-1", authors: ["Replacement"]))
        }

        XCTAssertNil(merged)
        XCTAssertEqual(store.book(forIdentifier: "book-1")?.bookAuthors?.first?.name, "Author")
        XCTAssertEqual(recorder.operations, ["updatedBookMetadata"])
    }

    /// A store's write marker must not admit a write on a different store, whose reads still run.
    func testWriteOnSecondStore_InsideItsReadNestedInFirstStoresWrite_IsReported() {
        let otherRecorder = WriteInsideReadRecorder()
        let other = makeStore(recorder: otherRecorder)
        var blockRan = false

        store.performBarrierSync {
            _ = other.performSync { other.performBarrierSync { blockRan = true } }
        }

        XCTAssertFalse(blockRan)
        XCTAssertEqual(otherRecorder.operations, ["performBarrierSync"])
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    /// A task started inside a write runs later, outside it; its reads must still count as reads.
    func testWriteInsideRead_InTaskStartedDuringWrite_IsReported() async {
        let store = store!
        var task: Task<Bool, Never>?

        store.performBarrierSync {
            task = Task { store.performSync { store.performBarrierSync {} } }
        }
        let ran = await task?.value

        XCTAssertEqual(ran, false)
        XCTAssertEqual(recorder.operations, ["performBarrierSync"])
    }

    // MARK: - A write inside a write still runs inline

    func testMutateRegistrySync_InsideAsyncWrite_RunsInline() async {
        await seed("book-1")
        let store = store!

        // @Sendable keeps the closure off the test's main-actor isolation; it runs on the store's queue.
        store.performBarrier { @Sendable in
            store.mutateRegistrySync { $0["book-1"]?.state = .downloadSuccessful }
        }
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(store.state(for: "book-1"), .downloadSuccessful)
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    func testPerformBarrierSync_InsideSyncWrite_RunsInline() {
        var innerRan = false
        var innerReturned = false

        let outerRan = store.performBarrierSync {
            innerReturned = store.performBarrierSync { innerRan = true }
        }

        XCTAssertTrue(outerRan)
        XCTAssertTrue(innerRan)
        XCTAssertTrue(innerReturned, "an inline write reports that it ran")
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    /// A write on another store inside this store's write must hand the marker back afterwards.
    func testWriteAfterOtherStoresWrite_InsideWrite_StillRunsInline() {
        let otherRecorder = WriteInsideReadRecorder()
        let other = makeStore(recorder: otherRecorder)
        var otherRan = false
        var laterWriteRan = false

        store.performBarrierSync {
            other.performBarrierSync { otherRan = true }
            store.performBarrierSync { laterWriteRan = true }
        }

        XCTAssertTrue(otherRan)
        XCTAssertTrue(laterWriteRan)
        XCTAssertTrue(recorder.operations.isEmpty)
        XCTAssertTrue(otherRecorder.operations.isEmpty)
    }

    /// A queued write does not keep the store alive, and still runs after the store is released.
    func testQueuedAsyncWrite_RunsAfterStoreIsReleased() async {
        let gate = DispatchSemaphore(value: 0)
        let ran = expectation(description: "queued write ran")
        var released: BookRegistryStore? = makeStore(recorder: recorder)
        weak var weakStore = released

        released?.performBarrier { @Sendable in gate.wait() }
        released?.performBarrier { @Sendable in ran.fulfill() }
        released = nil
        XCTAssertNil(weakStore, "queued writes must not keep the store alive")
        gate.signal()

        await fulfillment(of: [ran], timeout: 5)
    }

    /// A read nested in a write is still inside the write, so a write under it stays exclusive.
    func testWrite_InsideReadNestedInWrite_RunsInline() async {
        await seed("book-1")

        store.mutateRegistrySync({ _ in }, onComplete: {
            self.store.readRegistry { _ in
                self.store.mutateRegistrySync { $0["book-1"]?.state = .used }
            }
        })

        XCTAssertEqual(store.state(for: "book-1"), .used)
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    func testUpdatedBookMetadata_InsideWrite_RunsInline() async {
        await seed("book-1")
        var merged: TPPBook?

        store.performBarrierSync {
            merged = store.updatedBookMetadata(makeBook(identifier: "book-1", authors: ["Replacement"]))
        }

        XCTAssertEqual(merged?.bookAuthors?.first?.name, "Replacement")
        XCTAssertEqual(store.book(forIdentifier: "book-1")?.bookAuthors?.first?.name, "Replacement")
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    // MARK: - Reads and writes from outside the store

    func testReadsAndWritesFromOutside_BehaveAsBefore() async {
        await seed("book-1")
        var onCompleteSawWrite = false

        store.mutateRegistrySync({ $0["book-1"]?.state = .downloadSuccessful }, onComplete: {
            onCompleteSawWrite = self.store.state(for: "book-1") == .downloadSuccessful
        })
        let merged = store.updatedBookMetadata(makeBook(identifier: "book-1", authors: ["Replacement"]))
        let readState = store.readRegistry { $0["book-1"]?.state }

        XCTAssertTrue(onCompleteSawWrite)
        XCTAssertEqual(readState, .downloadSuccessful)
        XCTAssertEqual(merged?.bookAuthors?.first?.name, "Replacement")
        XCTAssertTrue(store.performBarrierSync {})
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    // MARK: - Concurrency

    /// Many readers and writers, including writes nested in writes: no write is lost or misreported.
    /// Under TSan it also checks the reads and writes for races.
    func testConcurrentReadersAndWriters_ApplyEveryWriteAndReportNothing() async {
        let identifiers = (0..<8).map { "book-\($0)" }
        for identifier in identifiers {
            store.addBook(makeBook(identifier: identifier), state: .downloadNeeded)
        }
        await store._awaitPendingWritesForTesting()
        let store = store!
        let iterations = 400

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let identifier = identifiers[i % identifiers.count]
            switch i % 4 {
            case 0:
                store.mutateRegistrySync { registry in
                    registry[identifier]?.fulfillmentId = "\((Int(registry[identifier]?.fulfillmentId ?? "0") ?? 0) + 1)"
                }
            case 1:
                store.performBarrierSync {
                    store.mutateRegistrySync { registry in
                        registry[identifier]?.fulfillmentId = "\((Int(registry[identifier]?.fulfillmentId ?? "0") ?? 0) + 1)"
                    }
                }
            case 2:
                _ = store.readRegistry { $0.values.map(\.state) }
                _ = store.allBooks
            default:
                _ = store.state(for: identifier)
                _ = store.registrySnapshot()
            }
        }

        let total = identifiers.reduce(0) { $0 + (Int(store.fulfillmentId(forIdentifier: $1) ?? "0") ?? 0) }
        XCTAssertEqual(total, iterations / 2, "every write applied exactly once")
        XCTAssertTrue(recorder.operations.isEmpty)
    }
}

private final class WriteInsideReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ operation: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(operation)
    }

    var operations: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
