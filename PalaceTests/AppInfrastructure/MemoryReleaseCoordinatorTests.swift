//
//  MemoryReleaseCoordinatorTests.swift
//  PalaceTests
//
//  One memory warning runs every registered release step once, in stage
//  order, with the memory event line recorded first (PP-5580).
//

import UIKit
import XCTest
@testable import Palace
@testable import PalaceBookModel

final class MemoryReleaseCoordinatorTests: XCTestCase {

    /// Collects the steps a warning ran, from any thread.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
        func reset() { lock.withLock { entries.removeAll() } }
    }

    private final class Owner {
        let name: String
        init(_ name: String) { self.name = name }
    }

    private var center: NotificationCenter!
    private var sut: MemoryReleaseCoordinator!
    private var log: Log!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        sut = MemoryReleaseCoordinator(center: center)
        log = Log()
    }

    override func tearDown() {
        sut = nil
        center = nil
        log = nil
        super.tearDown()
    }

    private func register(_ owner: Owner, _ stage: MemoryReleaseStage) {
        let log = self.log!
        sut.register(owner, stage: stage) { log.append($0.name) }
    }

    private func postWarning() {
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// A memory warning releases the decoded covers that book objects hold
    /// (PP-5583); before, the cover store ignored warnings.
    func testRegisterBookCovers_warningReleasesTheCoverStoresImages() {
        let store = BookCoverStore(limits: .init(byteLimit: .max, keepRecent: 0))
        let book = Self.makeBook("warning-cover", store: store)
        book.coverImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        XCTAssertGreaterThan(store.imageByteCount, 0, "precondition: the store holds the cover")

        sut.registerBookCovers(store)
        postWarning()

        XCTAssertEqual(store.imageByteCount, 0)
        withExtendedLifetime(book) {}
    }

    /// A background trim runs only the stages it names, still in stage order (PP-5581).
    func testReleaseAllStages_RunsOnlyNamedStages_InStageOrder() {
        let owners = [
            (Owner("downloads"), MemoryReleaseStage.downloads),
            (Owner("images"), .decodedImages),
            (Owner("lcp"), .lcpDecrypt),
            (Owner("cells"), .bookCells),
            (Owner("record"), .record)
        ]
        for (owner, stage) in owners { register(owner, stage) }

        sut.releaseAll(stages: [.decodedImages, .bookCells])

        XCTAssertEqual(log.all, ["cells", "images"])
        withExtendedLifetime(owners) {}
    }

    /// The playing book's cover is kept when the store's step runs (PP-5581).
    func testRegisterBookCovers_KeepsTheIdentifiersTheProviderNames() {
        let store = BookCoverStore(limits: .init(byteLimit: .max, keepRecent: 0))
        let playing = Self.makeBook("playing-cover", store: store)
        let other = Self.makeBook("other-cover", store: store)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        playing.coverImage = cover
        other.coverImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }

        sut.registerBookCovers(store, keeping: { ["playing-cover"] })
        postWarning()

        XCTAssertIdentical(store.state(for: "playing-cover").coverImage, cover)
        XCTAssertNil(store.state(for: "other-cover").coverImage)
        withExtendedLifetime([playing, other]) {}
    }

    private static func makeBook(_ identifier: String, store: BookCoverStore) -> TPPBook {
        TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Title",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache(),
            coverStore: store
        )
    }

    func testWarning_runsStepsInStageOrder_notRegistrationOrder() {
        let images = Owner("decodedImages")
        let record = Owner("record")
        let network = Owner("networkResponses")
        let disk = Owner("diskSpace")
        register(images, .decodedImages)
        register(disk, .diskSpace)
        register(network, .networkResponses)
        register(record, .record)

        postWarning()

        XCTAssertEqual(log.all, ["record", "networkResponses", "decodedImages", "diskSpace"])
    }

    func testWarning_runsSynchronouslyBeforePostReturns() {
        let feeds = Owner("catalogFeeds")
        register(feeds, .catalogFeeds)

        postWarning()

        XCTAssertEqual(log.all, ["catalogFeeds"], "Callers rely on the release being done when post returns")
    }

    func testOwnersInOneStage_runInRegistrationOrder() {
        let first = Owner("first")
        let second = Owner("second")
        register(first, .cachedData)
        register(second, .cachedData)

        postWarning()

        XCTAssertEqual(log.all, ["first", "second"])
    }

    func testReleasedOwner_isNotCalledAndNotRetained() {
        weak var weakGone: Owner?
        do {
            let gone = Owner("gone")
            weakGone = gone
            register(gone, .bookCells)
        }
        let kept = Owner("kept")
        register(kept, .bookCells)

        postWarning()

        XCTAssertNil(weakGone, "The coordinator must hold owners weakly")
        XCTAssertEqual(log.all, ["kept"])
    }

    func testEachWarning_runsEachStepOnce() {
        let lcp = Owner("lcpDecrypt")
        register(lcp, .lcpDecrypt)

        postWarning()
        postWarning()

        XCTAssertEqual(log.all, ["lcpDecrypt", "lcpDecrypt"])
    }

    func testOtherNotificationCenters_doNotTrigger() {
        let feeds = Owner("catalogFeeds")
        register(feeds, .catalogFeeds)

        NotificationCenter().post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        XCTAssertTrue(log.all.isEmpty)
    }

    /// Random registrations, releases and warnings. After each warning the
    /// steps that ran are exactly the live owners, each once, sorted by stage
    /// and then by registration.
    func testRandomizedRegistrationsAndWarnings_keepOrderAndOnceEach() {
        let seed = UInt64.random(in: 1...UInt64.max)
        var rng = SplitMix64(seed: seed)
        var live: [(owner: Owner, stage: MemoryReleaseStage, index: Int)] = []
        var registered = 0

        for _ in 0..<400 {
            switch rng.next() % 4 {
            case 0, 1:
                let stage = MemoryReleaseStage.allCases[Int(rng.next() % UInt64(MemoryReleaseStage.allCases.count))]
                let owner = Owner("o\(registered)")
                register(owner, stage)
                live.append((owner, stage, registered))
                registered += 1
            case 2 where !live.isEmpty:
                live.remove(at: Int(rng.next() % UInt64(live.count)))
            default:
                log.reset()
                postWarning()
                let expected = live
                    .sorted { ($0.stage, $0.index) < ($1.stage, $1.index) }
                    .map(\.owner.name)
                XCTAssertEqual(log.all, expected, "seed \(seed)")
                if log.all != expected { return }
            }
        }
    }

    func testStagesAreOrderedCheapestToRebuildFirst() {
        XCTAssertEqual(MemoryReleaseStage.allCases, [
            .record, .networkResponses, .catalogFeeds, .bookCells,
            .cachedData, .lcpDecrypt, .decodedImages, .downloads, .diskSpace
        ])
    }
}

/// A small seeded generator so a failing randomized run can be repeated.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
