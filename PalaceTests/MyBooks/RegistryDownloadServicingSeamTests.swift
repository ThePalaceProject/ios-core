//
//  RegistryDownloadServicingSeamTests.swift
//  PalaceTests
//
//  Pins the app-side `MyBooksDownloadCenter` conformance to the registry's
//  `RegistryDownloadServicing` seam (god-class-decomposition Wave 2b). The
//  `#if LCP` license-vs-content probe moved OUT of the package into this
//  conformance because SPM targets don't inherit the app's LCP define; these
//  tests lock the build-flavor-INDEPENDENT contract of the two probe methods —
//  the content-file-existence path (the whole method on noDRM, the non-LCP path
//  on DRM). The `.lcpl`-license-only branch is LCP-define + fixture gated and is
//  covered by the byte-identical relocation + noDRM launch verification (see the
//  wave intent's Deferred stanza).
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookRegistry
import PalaceBookModel
import PalaceCatalog

final class RegistryDownloadServicingSeamTests: XCTestCase {

    private func makeCenter() -> MyBooksDownloadCenter {
        MyBooksDownloadCenter(bookRegistry: TPPBookRegistryMock())
    }

    /// A plain (non-LCP) book is never "LCP content missing" — the branch that
    /// schedules a silent `.lcpa` re-download must not fire for it (and on noDRM
    /// this method is unconditionally false).
    func testLcpContentFileMissing_nonLCPBook_isFalse() {
        let center = makeCenter()
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        XCTAssertFalse(center.lcpContentFileMissing(for: book, account: "acct-\(UUID().uuidString)"),
                       "a non-LCP book is never flagged LCP-content-missing")
    }

    /// `contentFileSatisfied` reflects on-disk content-file existence for a
    /// non-LCP book: false when the file is absent, true once it exists. This is
    /// the load-path gate that decides whether a downloaded book heals to
    /// `.downloadNeeded` (orphan recovery) — a regression strands or re-downloads
    /// a patron's book.
    func testContentFileSatisfied_reflectsContentFileExistence() throws {
        let center = makeCenter()
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let account = "seam-\(UUID().uuidString)"

        guard let url = center.fileUrl(for: book, account: account) else {
            throw XCTSkip("fileUrl unavailable for the mock book in this environment")
        }

        // Absent → not satisfied.
        try? FileManager.default.removeItem(at: url)
        XCTAssertFalse(center.contentFileSatisfied(for: book, account: account),
                       "absent content file → not satisfied")

        // Present → satisfied (non-LCP path returns plain file existence).
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(center.contentFileSatisfied(for: book, account: account),
                      "present content file → satisfied")
    }

    #if LCP
    /// PP-4957: `contentPresence` must report a license-only LCP audiobook as
    /// `.present` (playable) when streaming is ON, so load-time reconciliation
    /// keeps it `.downloadSuccessful` across launches instead of downgrading
    /// `.downloadSuccessful`+`.licenseOnly` → `.downloadNeeded` and re-fetching the
    /// `.lcpa`. Flag OFF → `.licenseOnly` (download-first, unchanged). This is the
    /// seam side of the reconcile-durability fix (the reconcile arm for `.present`
    /// is covered by BookRegistryReconciliationTableTests). Deleting the
    /// streaming branch flips the ON assertion back to `.licenseOnly`.
    func testContentPresence_licenseOnlyLCPAudiobook_streamingOnReportsPresent() throws {
        let center = makeCenter()
        let book = makeLCPAudiobook()
        try XCTSkipUnless(LCPAudiobooks.canOpenBook(book),
                          "fixture must be recognized as an openable LCP audiobook")
        let account = "seam-\(UUID().uuidString)"

        guard let contentURL = center.fileUrl(for: book, account: account) else {
            throw XCTSkip("fileUrl unavailable for the mock LCP audiobook in this environment")
        }
        // License (.lcpl) present, content (.lcpa) absent — the streaming state.
        try? FileManager.default.removeItem(at: contentURL)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try FileManager.default.createDirectory(at: licenseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: licenseURL.path, contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(at: licenseURL) }

        center.lcpStreamingEnabledProvider = { false }
        XCTAssertEqual(center.contentPresence(for: book, account: account), .licenseOnly,
                       "streaming OFF: a license without content is .licenseOnly (download-first)")

        center.lcpStreamingEnabledProvider = { true }
        XCTAssertEqual(center.contentPresence(for: book, account: account), .present,
                       "streaming ON: the license alone is playable, so reconcile keeps the book .downloadSuccessful on reload")
    }

    /// Marketplace LCP audiobook in the `/loans/`-feed acquisition shape
    /// `LCPAudiobooks.canOpenBook` accepts (LCP license MIME on the default
    /// acquisition, `application/audiobook+lcp` as the terminal indirect child).
    private func makeLCPAudiobook() -> TPPBook {
        let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: lcpLicenseMIME,
            hrefURL: URL(string: "https://library.test/book.lcpl")!,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: "application/audiobook+lcp", indirectAcquisitions: [])
            ],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition], authors: [], categoryStrings: [], distributor: "Test",
            identifier: UUID().uuidString, imageURL: nil, imageThumbnailURL: nil, published: Date(),
            publisher: "Test", subtitle: nil, summary: nil, title: "Test LCP Audiobook", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil, relatedWorksURL: nil, previewLink: nil,
            seriesURL: nil, revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: [:],
            bookDuration: nil, imageCache: MockImageCache()
        )
    }
    #endif
}
