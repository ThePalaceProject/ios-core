//
//  BookDetailMetadataHydrationTests.swift
//  PalaceTests
//
//  Covers the detail-view hydration path that fills in metadata
//  the grouped-lane OPDS feed omits (PP-???). See
//  BookDetailViewModel.hydrateMetadataIfNeeded().
//

import XCTest
import PalacePreferences
import PalaceCatalog
@testable import Palace

@MainActor
final class BookDetailMetadataHydrationTests: XCTestCase {

    private let alternateURL = URL(string: "https://example.org/works/abc")!

    /// Per-test isolated AppContainer (swarm_47883816 work package A).
    /// Replaces ~30 in-test reads of `AppContainer.production().*`.
    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - Hydration triggers when metadata is missing

    func testHydrate_WhenAllTargetFieldsEmpty_PopulatesFromAlternateFeed() async throws {
        let sparse = makeBook(
            published: nil,
            publisher: nil,
            distributor: nil,
            categoryStrings: nil,
            alternateURL: alternateURL
        )
        let fresh = makeBook(
            published: iso("2015-08-04"),
            publisher: "Disney-Hyperion",
            distributor: "OverDrive",
            categoryStrings: ["Juvenile Fiction"],
            alternateURL: alternateURL
        )

        var fetchedURL: URL?
        let vm = BookDetailViewModel(
            book: sparse,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { url in
                fetchedURL = url
                return fresh
            }
        )

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(fetchedURL, alternateURL)
        XCTAssertEqual(vm.book.publisher, "Disney-Hyperion")
        XCTAssertEqual(vm.book.distributor, "OverDrive")
        XCTAssertEqual(vm.book.categoryStrings, ["Juvenile Fiction"])
        XCTAssertEqual(vm.book.published, iso("2015-08-04"))
    }

    // MARK: - Guard paths

    func testHydrate_WhenMetadataAlreadyPresent_DoesNotFetch() async {
        let populated = makeBook(
            published: iso("2015-08-04"),
            publisher: "Disney-Hyperion",
            distributor: "OverDrive",
            categoryStrings: ["Juvenile Fiction"],
            alternateURL: alternateURL
        )

        var fetchCount = 0
        let vm = BookDetailViewModel(
            book: populated,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in
                fetchCount += 1
                return nil
            }
        )

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(fetchCount, 0, "Hydrator must not run when metadata is already populated")
        XCTAssertEqual(vm.book.publisher, "Disney-Hyperion")
    }

    func testHydrate_WhenNoAlternateURL_DoesNotFetch() async {
        let sparseWithoutAlt = makeBook(
            published: nil,
            publisher: nil,
            distributor: nil,
            categoryStrings: nil,
            alternateURL: nil
        )

        var fetchCount = 0
        let vm = BookDetailViewModel(
            book: sparseWithoutAlt,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in
                fetchCount += 1
                return nil
            }
        )

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(fetchCount, 0, "Nothing to hydrate against without an alternate URL")
        XCTAssertNil(vm.book.publisher)
    }

    // MARK: - Preserves existing navigational state

    func testHydrate_PreservesAcquisitionAndNavigationalURLs() async {
        let relatedURL = URL(string: "https://example.org/related/abc")!
        let revokeURL = URL(string: "https://example.org/revoke/abc")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "https://example.org/acq/abc")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let sparse = makeBook(
            acquisitions: [acquisition],
            published: nil,
            publisher: nil,
            distributor: nil,
            categoryStrings: nil,
            alternateURL: alternateURL,
            relatedWorksURL: relatedURL,
            revokeURL: revokeURL
        )
        // Fresh entry from `alternateURL` may NOT include the related/revoke
        // links or the real acquisition — it shouldn't clobber them.
        let fresh = makeBook(
            acquisitions: [],
            published: iso("2015-08-04"),
            publisher: "Disney-Hyperion",
            distributor: "OverDrive",
            categoryStrings: ["Juvenile Fiction"],
            alternateURL: nil,
            relatedWorksURL: nil,
            revokeURL: nil
        )

        let vm = BookDetailViewModel(
            book: sparse,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in fresh }
        )

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(vm.book.publisher, "Disney-Hyperion")
        XCTAssertEqual(vm.book.relatedWorksURL, relatedURL,
                       "relatedWorksURL must survive hydration so More-by-Author keeps working")
        XCTAssertEqual(vm.book.revokeURL, revokeURL)
        XCTAssertEqual(vm.book.acquisitions.count, 1,
                       "Borrow acquisition must survive hydration")
    }

    // MARK: - Helpers

    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: s)!
    }

    private func makeBook(
        acquisitions: [TPPOPDSAcquisition]? = nil,
        published: Date?,
        publisher: String?,
        distributor: String?,
        categoryStrings: [String]?,
        alternateURL: URL?,
        relatedWorksURL: URL? = nil,
        revokeURL: URL? = nil,
        audience: String? = nil,
        language: String? = nil
    ) -> TPPBook {
        let identifier = "test-\(UUID().uuidString)"
        let defaultAcquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "https://example.org/acq")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: acquisitions ?? [defaultAcquisition],
            authors: [TPPBookAuthor(authorName: "Rick Riordan", relatedBooksURL: nil)],
            categoryStrings: categoryStrings,
            distributor: distributor,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: published,
            publisher: publisher,
            subtitle: nil,
            summary: "Summary",
            title: "The Blood of Olympus",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: alternateURL,
            relatedWorksURL: relatedWorksURL,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: revokeURL,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            audience: audience,
            language: language,
            imageCache: MockImageCache()
        )
    }

    // MARK: - PP-4046: Hydrate audience + language

    func testHydrate_PopulatesAudienceAndLanguageFromAlternateFeed() async throws {
        let sparse = makeBook(
            published: nil,
            publisher: nil,
            distributor: nil,
            categoryStrings: nil,
            alternateURL: alternateURL,
            audience: nil,
            language: nil
        )
        let fresh = makeBook(
            published: iso("2015-08-04"),
            publisher: "Disney-Hyperion",
            distributor: "OverDrive",
            categoryStrings: ["Juvenile Fiction"],
            alternateURL: alternateURL,
            audience: "Young Adult",
            language: "en"
        )

        let vm = BookDetailViewModel(
            book: sparse,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in fresh }
        )

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(vm.book.audience, "Young Adult",
                       "Hydration must fill in audience from the alternate feed")
        XCTAssertEqual(vm.book.language, "en",
                       "Hydration must fill in language from the alternate feed")
    }

    func testHydrate_TriggeredWhenOnlyAudienceOrLanguageMissing_DoesNotFireIfOthersPopulated() async {
        // If everything else is populated, a missing audience/language alone is
        // not worth a network round-trip — we only hydrate when the row is
        // *fully* empty. This guards against a hot-path regression where every
        // sparse-on-audience book triggers an alternate-feed fetch.
        let mostlyPopulated = makeBook(
            published: iso("2015-08-04"),
            publisher: "Disney-Hyperion",
            distributor: "OverDrive",
            categoryStrings: ["Juvenile Fiction"],
            alternateURL: alternateURL,
            audience: nil,
            language: nil
        )
        var fetchCount = 0
        let vm = BookDetailViewModel(
            book: mostlyPopulated,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in fetchCount += 1; return nil }
        )

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(fetchCount, 0,
                       "Audience/language alone are not strong enough signals to trigger hydration")
    }
}
