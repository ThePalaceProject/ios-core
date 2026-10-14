//
//  CoverDebugLabelsTests.swift
//  PalaceTests
//
//  PP-5285: the format and DRM labels drawn on covers when the Testing menu
//  toggle is on. Values come from the last content type of each acquisition
//  path, so the same title reads the same on every Palace client.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class CoverDebugLabelsTests: XCTestCase {

    // MARK: - Builders

    private func leaf(_ type: String) -> TPPOPDSIndirectAcquisition {
        TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: [])
    }

    private func chain(_ types: [String]) -> TPPOPDSIndirectAcquisition {
        var node = leaf(types.last!)
        for type in types.dropLast().reversed() {
            node = TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: [node])
        }
        return node
    }

    /// An acquisition whose path is `type`, then `indirect` (outermost first).
    /// A borrow acquisition whose path is `type`, then `indirect`.
    private func borrow(_ type: String, _ indirect: [String] = []) -> TPPOPDSAcquisition {
        acquisition(.borrow, type, indirect)
    }

    private func acquisition(_ relation: TPPOPDSAcquisitionRelation,
                             _ type: String,
                             _ indirect: [String] = []) -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: relation,
            type: type,
            hrefURL: URL(string: "https://example.com/acquire")!,
            indirectAcquisitions: indirect.isEmpty ? [] : [chain(indirect)],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
    }

    private let entry = ContentTypeOPDSCatalog
    private let lcpLicense = "application/vnd.readium.lcp.license.v1.0+json"
    private let acsm = "application/vnd.adobe.adept+xml"
    private let boundless = "application/vnd.thepalaceproject.baker-taylor.kdrm+json"
    private let findaway = "application/vnd.librarysimplified.findaway.license+json"
    private let overdriveAudio = "application/vnd.overdrive.circulation.api+json;profile=audiobook"
    private let axisNow = "application/vnd.librarysimplified.axisnow+json"

    // MARK: - Mapping table

    func testLabels_matchTheFinalContentTypeOfEachAcquisitionPath() {
        let cases: [(name: String, acquisitions: [TPPOPDSAcquisition], format: String, drm: String)] = [
            ("open-access EPUB", [acquisition(.openAccess, ContentTypeEpubZip)], "epub", "none"),
            ("LCP EPUB: the license is not the final type", [borrow(entry, [lcpLicense, ContentTypeEpubZip])], "epub", "none"),
            ("LCP license as the final type", [borrow(entry, [lcpLicense])], "unknown", "LCP"),
            ("LCP audiobook", [borrow(entry, [lcpLicense, ContentTypeAudiobookLCP])], "audiobook", "LCP"),
            ("Adobe EPUB: the ACSM is not the final type", [borrow(entry, [acsm, ContentTypeEpubZip])], "epub", "none"),
            ("ACSM as the final type", [borrow(entry, [acsm])], "unknown", "Adobe"),
            ("Boundless license as the final type", [borrow(entry, [boundless])], "unknown", "Boundless"),
            ("Findaway audiobook", [borrow(entry, [findaway])], "audiobook", "Findaway"),
            ("OverDrive audiobook, parameter ignored", [borrow(entry, [ContentTypeBearerToken, overdriveAudio])], "audiobook", "Overdrive"),
            ("Axis 360 EPUB", [borrow(entry, [axisNow])], "epub", "none"),
            ("open-access PDF", [acquisition(.openAccess, ContentTypeOpenAccessPDF)], "pdf", "none"),
            ("LCP PDF", [borrow(entry, [lcpLicense, ContentTypeReadiumLCPPDF])], "pdf", "none"),
            ("MP3 audiobook", [acquisition(.openAccess, "audio/mpeg")], "audiobook", "none"),
            ("Feedbooks audiobook, profile ignored", [borrow(entry, [ContentTypeFeedbooksAudiobook])], "audiobook", "none"),
            ("unrecognised type", [acquisition(.openAccess, "text/html")], "unknown", "none"),
            ("no acquisitions", [], "unknown", "none"),
            ("type case is ignored", [borrow(entry, ["Application/EPUB+ZIP"])], "epub", "none"),
        ]

        for c in cases {
            let labels = CoverDebugLabels.labels(for: c.acquisitions)
            XCTAssertEqual(labels.format, c.format, "format for \(c.name)")
            XCTAssertEqual(labels.drm, c.drm, "DRM for \(c.name)")
        }
    }

    // MARK: - Ordering

    func testFormat_isTakenFromTheFirstAcquisitionThatHasOne() {
        let labels = CoverDebugLabels.labels(for: [
            acquisition(.openAccess, ContentTypeOpenAccessPDF),
            acquisition(.openAccess, ContentTypeEpubZip),
        ])
        XCTAssertEqual(labels.format, "pdf")
    }

    func testFormat_withinOneAcquisition_prefersEPUBThenAudiobookThenPDF() {
        let both = TPPOPDSAcquisition(
            relation: .borrow,
            type: entry,
            hrefURL: URL(string: "https://example.com/acquire")!,
            indirectAcquisitions: [leaf(ContentTypeOpenAccessPDF), leaf("audio/mpeg"), leaf(ContentTypeEpubZip)],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        XCTAssertEqual(CoverDebugLabels.labels(for: [both]).format, "epub")

        let audioAndPDF = TPPOPDSAcquisition(
            relation: .borrow,
            type: entry,
            hrefURL: URL(string: "https://example.com/acquire")!,
            indirectAcquisitions: [leaf(ContentTypeOpenAccessPDF), leaf("audio/mpeg")],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        XCTAssertEqual(CoverDebugLabels.labels(for: [audioAndPDF]).format, "audiobook")
    }

    func testDRM_LCPOutranksEveryOtherScheme() {
        let labels = CoverDebugLabels.labels(for: [
            borrow(entry, [acsm]),
            borrow(entry, [findaway]),
            borrow(entry, [lcpLicense, ContentTypeAudiobookLCP]),
        ])
        XCTAssertEqual(labels.drm, "LCP")
    }

    func testDRM_ordersAdobeBoundlessFindawayOverdrive() {
        XCTAssertEqual(CoverDebugLabels.labels(for: [borrow(entry, [overdriveAudio]), borrow(entry, [acsm])]).drm, "Adobe")
        XCTAssertEqual(CoverDebugLabels.labels(for: [borrow(entry, [overdriveAudio]), borrow(entry, [boundless])]).drm, "Boundless")
        XCTAssertEqual(CoverDebugLabels.labels(for: [borrow(entry, [overdriveAudio]), borrow(entry, [findaway])]).drm, "Findaway")
    }

    // MARK: - Sample and preview links

    func testSampleAndPreviewLinks_doNotDecideTheLabels() {
        let labels = CoverDebugLabels.labels(for: [
            acquisition(.sample, ContentTypeEpubZip),
            acquisition(.preview, lcpLicense, [ContentTypeAudiobookLCP]),
            acquisition(.openAccess, ContentTypeOpenAccessPDF),
        ])
        XCTAssertEqual(labels.format, "pdf", "a sample EPUB must not label a PDF title as EPUB")
        XCTAssertEqual(labels.drm, "none", "a preview's LCP must not label the title as LCP")
    }

    // MARK: - The toggle

    func testOverlay_whenDisabled_drawsNothing() {
        let acquisitions = [borrow(entry, [lcpLicense, ContentTypeAudiobookLCP])]
        XCTAssertNil(CoverDebugLabels.overlay(for: acquisitions, enabled: false))
    }

    func testOverlay_whenEnabled_carriesTheLabels() {
        let acquisitions = [borrow(entry, [lcpLicense, ContentTypeAudiobookLCP])]
        XCTAssertEqual(CoverDebugLabels.overlay(for: acquisitions, enabled: true),
                       CoverDebugLabels(format: "audiobook", drm: "LCP"))
    }
}

/// The setting behind the Testing menu toggle, against an isolated store.
final class CoverDebugLabelsSettingTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.CoverDebugLabels.\(ProcessInfo.processInfo.globallyUniqueString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetting_isOffWhenNeverSet() {
        XCTAssertFalse(DebugSettings(defaults: defaults).showsCoverFormatAndDRMLabels)
    }

    func testSetting_persistsAcrossInstances() {
        DebugSettings(defaults: defaults).showsCoverFormatAndDRMLabels = true
        XCTAssertTrue(DebugSettings(defaults: defaults).showsCoverFormatAndDRMLabels,
                      "a relaunch builds a new DebugSettings over the same store")
    }

    /// The cover reads the key directly through `@AppStorage`; this pins that
    /// the setting writes under that same key.
    func testSetting_writesTheKeyTheCoverReads() {
        DebugSettings(defaults: defaults).showsCoverFormatAndDRMLabels = true
        XCTAssertTrue(defaults.bool(forKey: DebugSettings.coverFormatAndDRMLabelsKey))
    }

    func testResetAll_turnsTheLabelsOff() {
        let settings = DebugSettings(defaults: defaults)
        settings.showsCoverFormatAndDRMLabels = true
        settings.resetAll()
        XCTAssertFalse(settings.showsCoverFormatAndDRMLabels)
    }
}
