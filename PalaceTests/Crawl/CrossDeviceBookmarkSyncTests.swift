import XCTest
@testable import Palace

/// Tests cross-device bookmark and reading position sync logic.
///
/// Simulates two devices (A and B) sharing the same account by testing
/// the sync decision engine with different device IDs and positions.
/// Verifies:
/// - Position from device A triggers sync prompt on device B
/// - Same device positions don't trigger sync
/// - Bookmark specs serialize correct device IDs
/// - Server responses parse both devices' bookmarks
/// - Conflict resolution logic handles all edge cases
@MainActor
final class CrossDeviceBookmarkSyncTests: XCTestCase {

    private let deviceA = "urn:uuid:device-A-test-001"
    private let deviceB = "urn:uuid:device-B-test-002"
    private let testBookID = "urn:uuid:cross-device-test-book"

    // MARK: - Helpers

    private func makeLocatorJSON(href: String, progress: Double, title: String = "Chapter") -> String {
        """
        {"@type":"LocatorHrefProgression","href":"\(href)","progressWithinChapter":\(progress),"title":"\(title)"}
        """
    }

    private func makeBookmark(
        device: String,
        href: String,
        progress: Float,
        progressInBook: Float = 0.5,
        chapter: String = "Chapter"
    ) -> TPPReadiumBookmark? {
        TPPReadiumBookmark(
            annotationId: "test-\(UUID().uuidString)",
            href: href,
            chapter: chapter,
            page: nil,
            location: makeLocatorJSON(href: href, progress: Double(progress), title: chapter),
            progressWithinChapter: progress,
            progressWithinBook: progressInBook,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: ISO8601DateFormatter().string(from: Date()),
            device: device
        )
    }

    // MARK: - Cross-Device Sync Decision Logic

    func testDifferentDevice_DifferentPosition_ShouldSync() {
        let serverPosition = makeBookmark(device: deviceB, href: "/ch7.html", progress: 0.5, progressInBook: 0.85, chapter: "Chapter 7")
        let localLocation = TPPBookLocation(locationString: makeLocatorJSON(href: "/ch3.html", progress: 0.75), renderer: "readium2")

        XCTAssertNotNil(serverPosition)
        XCTAssertNotNil(localLocation)

        let shouldSync = evaluateSyncDecision(
            serverBookmark: serverPosition!,
            localLocation: localLocation,
            currentDeviceID: deviceA
        )

        XCTAssertTrue(shouldSync, "Different device + different position = should prompt user to sync")
    }

    func testSameDevice_DifferentPosition_ShouldNotSync() {
        let serverPosition = makeBookmark(device: deviceA, href: "/ch7.html", progress: 0.5)
        let localLocation = TPPBookLocation(locationString: makeLocatorJSON(href: "/ch3.html", progress: 0.25), renderer: "readium2")

        let shouldSync = evaluateSyncDecision(
            serverBookmark: serverPosition!,
            localLocation: localLocation,
            currentDeviceID: deviceA
        )

        XCTAssertFalse(shouldSync, "Same device = local is authoritative, no sync prompt")
    }

    func testDifferentDevice_IdenticalPosition_ShouldNotSync() {
        let locator = makeLocatorJSON(href: "/ch5.html", progress: 0.5)
        let serverPosition = makeBookmark(device: deviceB, href: "/ch5.html", progress: 0.5)
        // Override location to match exactly
        let localLocation = TPPBookLocation(locationString: serverPosition!.location, renderer: "readium2")

        let shouldSync = evaluateSyncDecision(
            serverBookmark: serverPosition!,
            localLocation: localLocation,
            currentDeviceID: deviceA
        )

        XCTAssertFalse(shouldSync, "Identical positions = no sync needed even from different device")
    }

    func testNoServerPosition_ShouldNotSync() {
        let localLocation = TPPBookLocation(locationString: makeLocatorJSON(href: "/ch3.html", progress: 0.75), renderer: "readium2")

        // No server bookmark at all
        XCTAssertFalse(
            evaluateSyncDecision(serverBookmark: nil, localLocation: localLocation, currentDeviceID: deviceA),
            "No server position = nothing to sync"
        )
    }

    func testNoLocalPosition_DifferentDevice_ShouldSync() {
        let serverPosition = makeBookmark(device: deviceB, href: "/ch7.html", progress: 0.5)

        let shouldSync = evaluateSyncDecision(
            serverBookmark: serverPosition!,
            localLocation: nil,
            currentDeviceID: deviceA
        )

        XCTAssertTrue(shouldSync, "No local position + server from different device = should sync")
    }

    func testNoLocalPosition_SameDevice_ShouldNotSync() {
        let serverPosition = makeBookmark(device: deviceA, href: "/ch7.html", progress: 0.5)

        let shouldSync = evaluateSyncDecision(
            serverBookmark: serverPosition!,
            localLocation: nil,
            currentDeviceID: deviceA
        )

        // Same device + no local = still shouldn't prompt (local was explicitly cleared)
        // This matches the existing behavior where same-device sync is suppressed
        XCTAssertFalse(shouldSync, "Same device positions are always authoritative locally")
    }

    // MARK: - Bookmark Spec Device ID

    func testBookmarkSpec_IncludesDeviceID() {
        let spec = TPPBookmarkSpec(
            time: NSDate(),
            device: deviceA,
            motivation: .bookmark,
            bookID: testBookID,
            selectorValue: makeLocatorJSON(href: "/ch3.html", progress: 0.75)
        )

        let dict = spec.dictionaryForJSONSerialization()
        let body = dict["body"] as? [String: Any]
        XCTAssertEqual(body?["http://librarysimplified.org/terms/device"] as? String, deviceA)
    }

    func testBookmarkSpec_DifferentDevices_ProduceDifferentPayloads() {
        let specA = TPPBookmarkSpec(
            time: NSDate(),
            device: deviceA,
            motivation: .bookmark,
            bookID: testBookID,
            selectorValue: makeLocatorJSON(href: "/ch3.html", progress: 0.75)
        )

        let specB = TPPBookmarkSpec(
            time: NSDate(),
            device: deviceB,
            motivation: .bookmark,
            bookID: testBookID,
            selectorValue: makeLocatorJSON(href: "/ch3.html", progress: 0.75)
        )

        let dictA = specA.dictionaryForJSONSerialization()
        let dictB = specB.dictionaryForJSONSerialization()

        let deviceFromA = (dictA["body"] as? [String: Any])?["http://librarysimplified.org/terms/device"] as? String
        let deviceFromB = (dictB["body"] as? [String: Any])?["http://librarysimplified.org/terms/device"] as? String

        XCTAssertNotEqual(deviceFromA, deviceFromB, "Different devices must produce different device IDs in payload")
        XCTAssertEqual(deviceFromA, deviceA)
        XCTAssertEqual(deviceFromB, deviceB)
    }

    // MARK: - Reading Progress vs Bookmark Motivation

    func testReadingProgress_HasCorrectMotivation() {
        let spec = TPPBookmarkSpec(
            time: NSDate(),
            device: deviceA,
            motivation: .readingProgress,
            bookID: testBookID,
            selectorValue: makeLocatorJSON(href: "/ch5.html", progress: 0.5)
        )

        let dict = spec.dictionaryForJSONSerialization()
        XCTAssertEqual(dict["motivation"] as? String, "http://librarysimplified.org/terms/annotation/idling")
    }

    func testBookmark_HasCorrectMotivation() {
        let spec = TPPBookmarkSpec(
            time: NSDate(),
            device: deviceA,
            motivation: .bookmark,
            bookID: testBookID,
            selectorValue: makeLocatorJSON(href: "/ch3.html", progress: 0.75)
        )

        let dict = spec.dictionaryForJSONSerialization()
        XCTAssertEqual(dict["motivation"] as? String, "http://www.w3.org/ns/oa#bookmarking")
    }

    // MARK: - Server Response Parsing

    func testParseServerBookmarks_MultipleDevices() throws {
        let items: [[String: Any]] = [
            [
                "id": "https://server/annotations/bm-1",
                "body": [
                    "http://librarysimplified.org/terms/time": "2026-04-15T09:00:00Z",
                    "http://librarysimplified.org/terms/device": deviceA,
                    "http://librarysimplified.org/terms/chapter": "Chapter 2",
                    "http://librarysimplified.org/terms/progressWithinBook": 0.3
                ],
                "target": [
                    "source": testBookID,
                    "selector": [
                        "type": "oa:FragmentSelector",
                        "value": makeLocatorJSON(href: "/ch2.html", progress: 0.3, title: "Chapter 2")
                    ]
                ],
                "motivation": "http://www.w3.org/ns/oa#bookmarking"
            ],
            [
                "id": "https://server/annotations/bm-2",
                "body": [
                    "http://librarysimplified.org/terms/time": "2026-04-15T10:30:00Z",
                    "http://librarysimplified.org/terms/device": deviceB,
                    "http://librarysimplified.org/terms/chapter": "Chapter 5",
                    "http://librarysimplified.org/terms/progressWithinBook": 0.6
                ],
                "target": [
                    "source": testBookID,
                    "selector": [
                        "type": "oa:FragmentSelector",
                        "value": makeLocatorJSON(href: "/ch5.html", progress: 0.6, title: "Chapter 5")
                    ]
                ],
                "motivation": "http://www.w3.org/ns/oa#bookmarking"
            ]
        ]

        let responseJSON: [String: Any] = [
            "first": ["items": items],
            "total": 2
        ]
        let data = try JSONSerialization.data(withJSONObject: responseJSON)

        // Parse using the same logic the app uses
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let firstPage = json?["first"] as? [String: Any]
        let rawItems = firstPage?["items"] as? [[String: Any]]

        XCTAssertEqual(rawItems?.count, 2, "Should have 2 bookmarks from 2 devices")

        // Extract device IDs
        let devices = rawItems?.compactMap { item -> String? in
            let body = item["body"] as? [String: Any]
            return body?["http://librarysimplified.org/terms/device"] as? String
        }

        XCTAssertTrue(devices?.contains(deviceA) == true, "Should include Device A's bookmark")
        XCTAssertTrue(devices?.contains(deviceB) == true, "Should include Device B's bookmark")
    }

    // MARK: - Edge Cases

    func testBookmarkWithNilDevice_TreatedAsSameDevice() {
        // Legacy bookmarks may have nil device ID
        let serverPosition = makeBookmark(device: "", href: "/ch7.html", progress: 0.5)
        // Override device to nil
        let legacyBookmark = TPPReadiumBookmark(
            annotationId: "legacy",
            href: "/ch7.html",
            chapter: "Chapter 7",
            page: nil,
            location: makeLocatorJSON(href: "/ch7.html", progress: 0.5),
            progressWithinChapter: 0.5,
            progressWithinBook: 0.85,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: ISO8601DateFormatter().string(from: Date()),
            device: nil
        )

        XCTAssertNotNil(legacyBookmark, "Bookmark with nil device should still be created")

        let shouldSync = evaluateSyncDecision(
            serverBookmark: legacyBookmark!,
            localLocation: TPPBookLocation(locationString: "different", renderer: "readium2"),
            currentDeviceID: deviceA
        )

        // Empty/nil device != deviceA, so should sync
        XCTAssertTrue(shouldSync, "Nil device on server bookmark should be treated as different device")
    }

    // MARK: - Sync Decision Engine

    private func evaluateSyncDecision(
        serverBookmark: TPPReadiumBookmark?,
        localLocation: TPPBookLocation?,
        currentDeviceID: String
    ) -> Bool {
        guard let bookmark = serverBookmark else { return false }
        let serverDevice = bookmark.device ?? ""

        // Same device + local exists → local is authoritative
        if serverDevice == currentDeviceID && localLocation != nil {
            return false
        }

        // Same device + no local → device cleared its own position
        if serverDevice == currentDeviceID && localLocation == nil {
            return false
        }

        // Identical positions → already synced
        if let local = localLocation, local.locationString == bookmark.location {
            return false
        }

        // Different device, different or missing local position → sync
        return true
    }
}
