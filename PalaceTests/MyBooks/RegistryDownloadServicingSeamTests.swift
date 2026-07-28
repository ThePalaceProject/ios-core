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
}
