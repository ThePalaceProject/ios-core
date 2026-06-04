import XCTest
import PalaceCatalog

@testable import Palace

class TPPOPDSAcquisitionPathTests: XCTestCase {

    var acquisitions: [TPPOPDSAcquisition]!

    override func setUp() {
        super.setUp()
        let bundle = Bundle(for: TPPOPDSAcquisitionPathTests.self)
        guard let url = bundle.url(forResource: "NYPLOPDSAcquisitionPathEntry", withExtension: "xml"),
              let data = try? Data(contentsOf: url),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to parse test XML")
            return
        }
        acquisitions = entry.acquisitions
    }

    func testSimplifiedAdeptEpubAcquisition() {
        let acquisitionPaths: [TPPOPDSAcquisitionPath] =
            TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
                forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
                allowedRelations: TPPOPDSAcquisitionRelationSet([.borrow, .openAccess]).rawValue,
                acquisitions: acquisitions)

        XCTAssert(acquisitionPaths.count == 2)

        XCTAssert(acquisitionPaths[0].relation == TPPOPDSAcquisitionRelation.borrow)
        XCTAssert(acquisitionPaths[0].types == [
            "application/atom+xml;type=entry;profile=opds-catalog",
            "application/vnd.adobe.adept+xml",
            "application/epub+zip"
        ])

        XCTAssert(acquisitionPaths[1].relation == TPPOPDSAcquisitionRelation.borrow)
        XCTAssert(acquisitionPaths[1].types == [
            "application/atom+xml;type=entry;profile=opds-catalog",
            "application/pdf"
        ])
    }

    func testSampleLinkInAcquisitions() {
        // TPPOPDSAcquisitionPathEntryWithSampleLink.xml contains a sample link
        let bundle = Bundle(for: TPPOPDSAcquisitionPathTests.self)
        guard let url = bundle.url(forResource: "TPPOPDSAcquisitionPathEntryWithSampleLink", withExtension: "xml"),
              let data = try? Data(contentsOf: url),
              let xml = TPPXML(data: data),
              let entryWithSample = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to parse test XML with sample link")
            return
        }
        let bookWithSample = TPPBook(entry: entryWithSample)
        XCTAssertNotEqual(bookWithSample?.defaultAcquisition?.relation, .sample,
                          "Default acquisition must NOT be the sample link")
        XCTAssertEqual(bookWithSample?.sampleAcquisition?.relation, .sample,
                       "Sample acquisition must have the sample relation")
    }

    // MARK: - PP-4161: Streaming-HTML support

    /// PP-4161: The new LibrarySimplified streaming-media MIME must be in the
    /// supported-types set so OPDS2 publications whose only acquisition is a
    /// streaming-HTML leaf are no longer dropped by
    /// `OPDS2PublicationExtended`'s `hasOpenablePath` filter.
    func testTPPOPDSAcquisitionPath_supportedTypes_containsStreamingHTML() {
        let types = TPPOPDSAcquisitionPath.supportedTypes()
        XCTAssertTrue(types.contains(ContentTypeStreamingHTML),
                      "supportedTypes() must include ContentTypeStreamingHTML so streaming-media-only publications survive the OPDS2 filter")
        // Sanity: the constant itself is the expected LibrarySimplified MIME
        XCTAssertEqual(ContentTypeStreamingHTML,
                       "text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media")
    }

    /// PP-4161: When an OPDS2 publication offers a borrow link of type
    /// `application/opds-publication+json` with a streaming-HTML indirect
    /// leaf, the resolver must produce a path ending at the streaming-HTML
    /// MIME. This pins the leaf into `supportedSubtypes(forType: ContentTypeOPDSPublication)`.
    func testTPPOPDSAcquisitionPath_supportedSubtypes_forOPDSPublication_containsStreamingHTML() {
        let subs = TPPOPDSAcquisitionPath.supportedSubtypes(forType: ContentTypeOPDSPublication)
        XCTAssertTrue(subs.contains(ContentTypeStreamingHTML),
                      "supportedSubtypes(forType: ContentTypeOPDSPublication) must include ContentTypeStreamingHTML as a leaf so the borrow → streaming-HTML chain resolves")
    }

    /// PP-4161: End-to-end path resolution — borrow link with streaming-HTML
    /// indirect leaf must produce exactly one path with the leaf type as
    /// the last entry. Without the supportedTypes + supportedSubtypes edits
    /// this returns zero paths.
    func testSupportedAcquisitionPaths_borrowToStreamingHTMLIndirect_producesStreamingPath() {
        let leaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeStreamingHTML,
            indirectAcquisitions: []
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSPublication,
            hrefURL: URL(string: "https://example.com/borrow/streaming-html")!,
            indirectAcquisitions: [leaf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
            acquisitions: [acquisition]
        )

        XCTAssertEqual(paths.count, 1,
                       "borrow → streaming-HTML indirect must resolve to exactly one supported path")
        XCTAssertEqual(paths.first?.types.last, ContentTypeStreamingHTML,
                       "Path leaf must be the streaming-HTML MIME so downstream callers route to the streaming reader")
        XCTAssertEqual(paths.first?.relation, .borrow)
    }
}
