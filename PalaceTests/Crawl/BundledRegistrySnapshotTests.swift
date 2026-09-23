import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BundledRegistrySnapshotTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled_snapshot_tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Stub resolver

    private struct StubResolver: BundleResourceResolving {
        let storage: [String: URL]

        func resourceURL(forName name: String, extension ext: String) -> URL? {
            storage["\(name).\(ext)"]
        }
    }

    private func writeSnapshot(_ json: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(BundledRegistrySnapshot.resourceName).\(BundledRegistrySnapshot.resourceExtension)")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - load(resolver:)

    func testLoad_WhenResourceMissing_ReturnsNil() {
        let resolver = StubResolver(storage: [:])
        XCTAssertNil(BundledRegistrySnapshot.load(resolver: resolver))
    }

    func testLoad_WhenResourceUnreadable_ReturnsNil() {
        let bogus = tempDir.appendingPathComponent("does_not_exist_\(UUID().uuidString).json")
        let resolver = StubResolver(storage: ["\(BundledRegistrySnapshot.resourceName).\(BundledRegistrySnapshot.resourceExtension)": bogus])
        XCTAssertNil(BundledRegistrySnapshot.load(resolver: resolver))
    }

    func testLoad_WhenResourcePresent_ReturnsBytes() throws {
        let payload = #"{"metadata":{"title":"Test"},"catalogs":[],"links":[]}"#
        let url = try writeSnapshot(payload)
        let resolver = StubResolver(storage: ["\(BundledRegistrySnapshot.resourceName).\(BundledRegistrySnapshot.resourceExtension)": url])

        let data = try XCTUnwrap(BundledRegistrySnapshot.load(resolver: resolver))
        XCTAssertEqual(String(data: data, encoding: .utf8), payload)
    }

    // MARK: - End-to-end: the loaded JSON parses into OPDS2CatalogsFeed

    func testLoad_RoundTripsThroughOPDS2CatalogsFeedDecoder() throws {
        let payload = """
        {
          "metadata": { "title": "Palace Library Registry", "numberOfItems": 2 },
          "catalogs": [
            {
              "metadata": { "id": "lib-1", "title": "Library One", "updated": "2026-04-15T10:00:00Z" },
              "links": [ { "href": "https://example.com/lib-1/catalog", "rel": "http://opds-spec.org/catalog" } ]
            },
            {
              "metadata": { "id": "lib-2", "title": "Library Two", "updated": "2026-04-15T11:00:00Z" },
              "links": [ { "href": "https://example.com/lib-2/catalog", "rel": "http://opds-spec.org/catalog" } ]
            }
          ],
          "links": [ { "href": "https://registry.palaceproject.io/libraries/crawlable", "rel": "self" } ]
        }
        """
        let url = try writeSnapshot(payload)
        let resolver = StubResolver(storage: ["\(BundledRegistrySnapshot.resourceName).\(BundledRegistrySnapshot.resourceExtension)": url])

        let data = try XCTUnwrap(BundledRegistrySnapshot.load(resolver: resolver))
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertEqual(feed.catalogs.count, 2)
        XCTAssertEqual(feed.catalogs.map(\.metadata.id), ["lib-1", "lib-2"])
    }

    // MARK: - Smoke test against the checked-in bundled file (if accessible)

    /// When the build pipeline embeds `bundled_registry.json` in the Palace
    /// host bundle, `Bundle.main` resolves the resource. This guard exits
    /// early when the test runs without the host app embed (e.g., a logic-
    /// only test target), so we don't false-positive a missing snapshot as
    /// a real failure.
    func testBundleMain_LoadsAValidSnapshotWhenEmbedded() throws {
        guard Bundle.main.url(forResource: BundledRegistrySnapshot.resourceName, withExtension: BundledRegistrySnapshot.resourceExtension) != nil else {
            throw XCTSkip("bundled_registry.json not embedded in this bundle — skipping smoke check")
        }
        let data = try XCTUnwrap(BundledRegistrySnapshot.load())
        let feed = try OPDS2CatalogsFeed.fromData(data)
        XCTAssertGreaterThan(feed.catalogs.count, 0,
                             "Embedded snapshot must contain at least one library")
    }
}
