//
//  LCPAdapterTests.swift
//  PalaceTests
//
//  Behavior tests for `LCPAdapter` — Module C of swarm_5c8ddbd5. Drives the
//  three-tier LCP source resolution (local file, license file, license
//  re-download) and the manifest-load failure branches through spy
//  collaborators. `LCPAudiobooks` instantiation is itself stubbed via the
//  injectable factory closure so the suite never reaches Readium / disk /
//  network.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if LCP

import XCTest
import PalaceCatalog
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class LCPAdapterTests: XCTestCase {

    // MARK: - MIME constants

    private let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
    private let opdsPublicationMIME = "application/opds-publication+json"
    private let audiobookLCPMIME = "application/audiobook+lcp"
    private let openAccessAudiobookMIME = "application/audiobook+json"

    // MARK: - Spies

    private final class SpyDownloadCenter: LCPAdapterDownloadCenter {
        var fileUrlByIdentifier: [String: URL] = [:]
        private(set) var fileUrlCallCount = 0
        func fileUrl(for identifier: String) -> URL? {
            fileUrlCallCount += 1
            return fileUrlByIdentifier[identifier]
        }
    }

    private final class SpyNetworkExecutor: LCPAdapterNetworkExecutor {
        var stubbedData: Data?
        var stubbedResponse: URLResponse?
        var stubbedError: Error?
        private(set) var capturedURL: URL?
        private(set) var getCallCount = 0

        func GET(
            _ reqURL: URL,
            completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void
        ) -> URLSessionDataTask? {
            getCallCount += 1
            capturedURL = reqURL
            completion(stubbedData, stubbedResponse, stubbedError)
            return nil
        }
    }

    // MARK: - Fixture helpers

    private func makeBook(
        acquisitionType: String,
        indirect: [TPPOPDSIndirectAcquisition] = [],
        hrefURL: URL = URL(string: "https://library.test/fulfill.lcpl")!
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: acquisitionType,
            hrefURL: hrefURL,
            indirectAcquisitions: indirect,
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: "lcp-book-\(UUID().uuidString)",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: nil,
            title: "LCP Test Book",
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
            imageCache: MockImageCache()
        )
    }

    private func indirect(_ type: String, _ children: [TPPOPDSIndirectAcquisition] = []) -> TPPOPDSIndirectAcquisition {
        TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: children)
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://library.test/fulfill.lcpl")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func tempBookFileURL(identifier: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCPAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(identifier).lcpa")
    }

    // MARK: - canHandle

    /// The smallest whole ZIP: an end-of-central-directory record and nothing
    /// else. The adapter now distinguishes a finished download from one still
    /// arriving, and that record is what a partial file lacks, so a test that
    /// means "the book is on disk" has to write one.
    private func writeWholeArchive(to url: URL) {
        var eocd = Data([0x50, 0x4B, 0x05, 0x06])
        eocd.append(Data(repeating: 0, count: 18))
        try? eocd.write(to: url)
    }

    /// PP-4407 fixture: top-level type is `application/opds-publication+json`
    /// (the Marketplace /groups/ JSON feed shape), LCP MIME nested inside
    /// `indirectAcquisitions`. `LCPAdapter.canHandle` must return TRUE so
    /// the loader routes this through the LCP chain.
    func testCanHandle_marketplaceJSONFeedFixture_returnsTrue() {
        let adapter = LCPAdapter(
            downloadCenter: SpyDownloadCenter(),
            networkExecutor: SpyNetworkExecutor()
        )
        let book = makeBook(
            acquisitionType: opdsPublicationMIME,
            indirect: [indirect(lcpLicenseMIME, [indirect(audiobookLCPMIME)])]
        )

        XCTAssertTrue(adapter.canHandle(book),
                      "PP-4407 Marketplace fixture must be claimed by LCPAdapter")
    }

    /// Classic `/loans/` XML feed shape — top-level LCP license MIME with
    /// audiobook+lcp nested.
    func testCanHandle_xmlFeedLCPFixture_returnsTrue() {
        let adapter = LCPAdapter(
            downloadCenter: SpyDownloadCenter(),
            networkExecutor: SpyNetworkExecutor()
        )
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )

        XCTAssertTrue(adapter.canHandle(book),
                      "Classic XML /loans/ feed LCP shape must be claimed")
    }

    /// OpenAccess audiobook: no LCP MIME anywhere. `LCPAdapter.canHandle`
    /// must decline so the chain falls through to OpenAccessAdapter.
    func testCanHandle_openAccessAudiobook_returnsFalse() {
        let adapter = LCPAdapter(
            downloadCenter: SpyDownloadCenter(),
            networkExecutor: SpyNetworkExecutor()
        )
        let book = makeBook(acquisitionType: openAccessAudiobookMIME)

        XCTAssertFalse(adapter.canHandle(book),
                       "Open-access audiobook must be declined so the chain falls through")
    }

    // MARK: - resolveManifest source selection

    /// Local `.lcpa` package exists on disk: the adapter must short-circuit
    /// to the LOCAL branch and pass that URL to the LCPAudiobooks factory.
    /// We assert the factory captured that exact URL. We also force the
    /// factory to return nil (instantiation failure) so the test never
    /// reaches Readium — what matters is *which URL the factory was asked
    /// about*, not what it returned.
    func testResolveManifest_localLCPAFile_usesLocalFile() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        // Write a placeholder file so `fileManager.fileExists(atPath:)` is true
        writeWholeArchive(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = localURL
        let network = SpyNetworkExecutor()
        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil // forces .lcpInstantiationFailed — we don't care; we want the URL
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedFactoryURL, localURL,
                       "Local file path must be passed to LCPAudiobooks factory")
        XCTAssertEqual(network.getCallCount, 0,
                       "Network MUST NOT be touched when local file exists")
    }

    /// A whole archive whose end-of-central-directory record carries a long
    /// comment is still the book. The record sits 22 bytes plus up to 65535 of
    /// comment from the end of the file, so a search window shorter than that
    /// would read a finished download as a partial one and stream a book the
    /// patron already holds.
    func testResolveManifest_wholeLCPAWithALongTrailingComment_usesLocalFile() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        var archive = Data([0x50, 0x4B, 0x05, 0x06])
        archive.append(Data(repeating: 0, count: 18))
        // The comment length lives in the record; the bytes that follow push the
        // signature this far back from the end of the file.
        archive.append(Data(repeating: 0x20, count: 64 * 1024))
        try? archive.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = localURL
        let network = SpyNetworkExecutor()
        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            capturedFactoryURL,
            localURL,
            "a complete archive must be read from disk however far back its record sits"
        )
        XCTAssertEqual(network.getCallCount, 0, "a book on disk must not be fetched")
    }

    /// A file too short to hold the record at all is a download that has barely
    /// started, not a book. Pins the length guard from below; the whole-archive
    /// fixture is exactly the minimum, so it pins it from above.
    func testResolveManifest_lcpaShorterThanTheRecord_usesLicenseFileInstead() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        // One byte short of the smallest end-of-central-directory record.
        var truncated = Data([0x50, 0x4B, 0x05, 0x06])
        truncated.append(Data(repeating: 0, count: 17))
        try? truncated.write(to: localURL)
        let licenseURL = localURL.deletingPathExtension().appendingPathExtension("lcpl")
        try? Data([0x7B, 0x7D]).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = localURL
        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: SpyNetworkExecutor(),
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            capturedFactoryURL,
            licenseURL,
            "a file too short to hold the record must be streamed from the origin"
        )
    }

    /// A path that exists but cannot be opened for reading is not a readable
    /// book, so the adapter must stream rather than assume the archive is whole.
    /// A directory at the content path is the reachable form: it answers
    /// `fileExists` and refuses a file handle.
    func testResolveManifest_lcpaPathThatCannotBeOpened_usesLicenseFileInstead() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        let licenseURL = localURL.deletingPathExtension().appendingPathExtension("lcpl")
        try? Data([0x7B, 0x7D]).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: localURL.path),
            "Precondition: the path must answer fileExists, or the test proves nothing"
        )

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = localURL
        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: SpyNetworkExecutor(),
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            capturedFactoryURL,
            licenseURL,
            "a path that cannot be read must not be taken for a finished download"
        )
    }

    /// A download still in progress must not be read as the book.
    ///
    /// The source tiers tested only that a local file EXISTS, and a partial
    /// download exists from its first byte. Opening it reads the archive from
    /// disk, and the file fills from the start, so a chapter early in the
    /// package plays at once while a chapter further in cannot be read until
    /// the download reaches it. A patron sees playback start on chapter 1 and
    /// stall on a resumed chapter until the download passes that point. The
    /// licence URL streams from the origin and has no such gap (PP-5368).
    func testResolveManifest_partiallyDownloadedLCPA_usesLicenseFileInstead() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        // A download in progress: real bytes, but no end-of-central-directory
        // record, because that is written last.
        try? Data(repeating: 0x41, count: 4096).write(to: localURL)
        let licenseURL = localURL.deletingPathExtension().appendingPathExtension("lcpl")
        try? Data([0x7B, 0x7D]).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = localURL
        let network = SpyNetworkExecutor()
        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            capturedFactoryURL,
            licenseURL,
            "an incomplete archive must be streamed from the origin, not read from disk"
        )
    }

    /// No local `.lcpa`, but a `.lcpl` license sibling file exists. The
    /// adapter must reach for that license file as the LCP source. We force
    /// the factory to nil for the same reason as the previous test.
    func testResolveManifest_licenseFileExists_usesLicenseFile() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        // Stub the file URL so the adapter can derive the .lcpl sibling.
        // The .lcpa path itself MUST NOT exist; the .lcpl sibling MUST exist.
        let baseURL = tempBookFileURL(identifier: book.identifier)
        let licenseURL = baseURL.deletingPathExtension().appendingPathExtension("lcpl")
        try? Data([0x02]).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: licenseURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = baseURL
        let network = SpyNetworkExecutor()
        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedFactoryURL, licenseURL,
                       "When only .lcpl exists, that license URL must be the LCP source")
        XCTAssertEqual(network.getCallCount, 0,
                       "Cached license file must skip the network re-download path")
    }

    /// No local `.lcpa`, no `.lcpl` sibling: the adapter must hit the
    /// network to re-download the license. We stub a success response so
    /// the test can also assert the license file lands at the expected
    /// path; the factory still returns nil to keep Readium out of the loop.
    func testResolveManifest_neitherLocalNorLicense_redownloadsLicense() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let baseURL = tempBookFileURL(identifier: book.identifier)
        // Ensure no .lcpa and no .lcpl exist at this base path.
        let licenseURL = baseURL.deletingPathExtension().appendingPathExtension("lcpl")
        defer { try? FileManager.default.removeItem(at: baseURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = baseURL
        let network = SpyNetworkExecutor()
        network.stubbedData = Data("license-bytes".utf8)
        network.stubbedResponse = httpResponse(status: 200)

        var capturedFactoryURL: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                capturedFactoryURL = url
                return nil
            }
        )

        let expectation = expectation(description: "resolveManifest completes")
        adapter.resolveManifest(for: book) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(network.getCallCount, 1, "Network re-download path must be entered")
        XCTAssertEqual(network.capturedURL, book.defaultAcquisition?.hrefURL,
                       "License re-download must hit the book's fulfill URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: licenseURL.path),
                      "Re-downloaded license bytes must be written to the .lcpl sibling path")
        XCTAssertEqual(capturedFactoryURL, licenseURL,
                       "Re-downloaded license URL must be passed to the LCP factory")
    }

    /// License re-download fails at the network layer. The adapter must
    /// surface `.licenseDownloadFailed` — NOT `.lcpInstantiationFailed` and
    /// NOT swallow the error silently.
    func testResolveManifest_redownloadFailure_failsWithLicenseDownloadFailed() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let baseURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: baseURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = baseURL
        let network = SpyNetworkExecutor()
        network.stubbedError = NSError(domain: "TestNet", code: -1009, userInfo: nil)

        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network
        )

        let expectation = expectation(description: "resolveManifest completes")
        var observedError: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result {
                observedError = err
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        guard case .licenseDownloadFailed = observedError else {
            XCTFail("Expected .licenseDownloadFailed, got \(String(describing: observedError))")
            return
        }
    }

    /// LCP source resolved (local file exists), but `LCPAudiobooks(for:)`
    /// returns nil — typically because the file isn't a valid LCP package.
    /// The adapter must surface `.lcpInstantiationFailed` distinctly so
    /// the caller can distinguish "no source" from "source unusable".
    func testResolveManifest_lcpInstantiationFailure_failsWithLcpInstantiationFailed() {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        writeWholeArchive(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = localURL

        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: SpyNetworkExecutor(),
            lcpAudiobooksFactory: { _ in nil } // forces instantiation failure
        )

        let expectation = expectation(description: "resolveManifest completes")
        var observedError: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result {
                observedError = err
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        guard case .lcpInstantiationFailed = observedError else {
            XCTFail("Expected .lcpInstantiationFailed, got \(String(describing: observedError))")
            return
        }
    }
}

#endif
