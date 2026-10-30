//
//  LCPAdapterTests.swift
//  PalaceTests
//
//  Behavior tests for `LCPAdapter`. Drives the
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
import ReadiumShared

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

        func fetchLicense(from reqURL: URL) async throws -> (Data, URLResponse?) {
            getCallCount += 1
            capturedURL = reqURL
            if let stubbedError { throw stubbedError }
            return (stubbedData ?? Data(), stubbedResponse)
        }
    }

    // MARK: - Fixture helpers

    private func makeBook(
        acquisitionType: String,
        indirect: [TPPOPDSIndirectAcquisition] = [],
        hrefURL: URL = URL(string: "https://library.test/fulfill.lcpl")!,
        availability: TPPOPDSAcquisitionAvailability = TPPOPDSAcquisitionAvailabilityUnlimited()
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: acquisitionType,
            hrefURL: hrefURL,
            indirectAcquisitions: indirect,
            availability: availability
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

    /// Fails the test if the directory cannot be made. With `try?` here a lost
    /// fixture surfaced as the adapter reaching for the network, which reads as
    /// a defect in the code under test rather than in the setup.
    private func tempBookFileURL(identifier: String, file: StaticString = #filePath, line: UInt = #line) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCPAdapterTests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Fixture directory could not be created: \(error)", file: file, line: line)
        }
        return dir.appendingPathComponent("\(identifier).lcpa")
    }

    // MARK: - canHandle

    /// The smallest whole ZIP: an end-of-central-directory record and nothing
    /// else. The adapter now distinguishes a finished download from one still
    /// arriving, and that record is what a partial file lacks, so a test that
    /// means "the book is on disk" has to write one.
    /// Setup bytes a test's assertions depend on. A silent `try?` here turns a
    /// missing fixture into a failure that names the code under test instead.
    private func writeFixture(
        _ data: Data,
        to url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try data.write(to: url)
        } catch {
            XCTFail("Fixture could not be written to \(url.lastPathComponent): \(error)", file: file, line: line)
        }
    }

    private func writeWholeArchive(to url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var eocd = Data([0x50, 0x4B, 0x05, 0x06])
        eocd.append(Data(repeating: 0, count: 18))
        do {
            try eocd.write(to: url)
        } catch {
            XCTFail("Fixture archive could not be written: \(error)", file: file, line: line)
        }
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
    func testResolveManifest_localLCPAFile_usesLocalFile() async {
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

        _ = await adapter.resolveManifest(for: book)

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
    func testResolveManifest_wholeLCPAWithALongTrailingComment_usesLocalFile() async {
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
        writeFixture(archive, to: localURL)
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

        _ = await adapter.resolveManifest(for: book)

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
    func testResolveManifest_lcpaShorterThanTheRecord_usesLicenseFileInstead() async {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        // One byte short of the smallest end-of-central-directory record.
        var truncated = Data([0x50, 0x4B, 0x05, 0x06])
        truncated.append(Data(repeating: 0, count: 17))
        writeFixture(truncated, to: localURL)
        let licenseURL = localURL.deletingPathExtension().appendingPathExtension("lcpl")
        writeFixture(Data([0x7B, 0x7D]), to: licenseURL)
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

        _ = await adapter.resolveManifest(for: book)

        XCTAssertEqual(
            capturedFactoryURL,
            licenseURL,
            "a file too short to hold the record must be streamed from the origin"
        )
    }

    /// A directory at the content path answers `fileExists` and refuses a file
    /// handle, so the adapter must stream rather than assume the archive is
    /// whole. Scoped deliberately to that case: a readable file that only
    /// momentarily refuses a handle is a different question, and the check
    /// cannot currently tell the two apart (PP-5368).
    func testResolveManifest_lcpaPathThatCannotBeOpened_usesLicenseFileInstead() async {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        do {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        } catch {
            XCTFail("Fixture directory could not be created: \(error)")
        }
        let licenseURL = localURL.deletingPathExtension().appendingPathExtension("lcpl")
        writeFixture(Data([0x7B, 0x7D]), to: licenseURL)
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

        _ = await adapter.resolveManifest(for: book)

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
    func testResolveManifest_partiallyDownloadedLCPA_usesLicenseFileInstead() async {
        let book = makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)]
        )
        let localURL = tempBookFileURL(identifier: book.identifier)
        // A download in progress: real bytes, but no end-of-central-directory
        // record, because that is written last.
        writeFixture(Data(repeating: 0x41, count: 4096), to: localURL)
        let licenseURL = localURL.deletingPathExtension().appendingPathExtension("lcpl")
        writeFixture(Data([0x7B, 0x7D]), to: licenseURL)
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

        _ = await adapter.resolveManifest(for: book)

        XCTAssertEqual(
            capturedFactoryURL,
            licenseURL,
            "an incomplete archive must be streamed from the origin, not read from disk"
        )
    }

    // MARK: - PP-5440: licences left by an earlier loan

    /// The loan the device test used: borrowed 2026-10-30T16:11:18Z, after the
    /// earlier loan's licence was issued (2026-10-29T19:27:42Z).
    private let loanSince = ISO8601DateFormatter().date(from: "2026-10-30T16:11:18Z")!
    private let earlierIssued = "2026-10-29T19:27:42Z"
    private let currentIssued = "2026-10-30T16:11:18Z"

    private func licenseJSON(id: String, issued: String? = nil, publication: String? = nil) -> Data {
        let issuedField = issued.map { ",\"issued\":\"\($0)\"" } ?? ""
        let links = publication.map { "[{\"rel\":\"publication\",\"href\":\"\($0)\"}]" } ?? "[]"
        return Data("{\"id\":\"\(id)\"\(issuedField),\"links\":\(links)}".utf8)
    }

    /// Creates the retained range store a streamed archive leaves, keyed the
    /// way `LCPAudiobooks` keys it, and returns its directory.
    private func makeArchiveStore(for publication: String) throws -> URL {
        let directory = try LCPAudiobooks.archiveStoreDirectory(for: try XCTUnwrap(HTTPURL(string: publication)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: directory.appendingPathComponent("ranges"))
        return directory
    }

    private func uniquePublication() -> String {
        "https://storage.test/pp5440-\(UUID().uuidString).lcpa"
    }

    /// Records every source the adapter hands to the factory across opens.
    private final class SourceLog {
        var sources: [URL] = []
    }

    private func makeAdapter(for book: TPPBook, contentURL: URL, network: SpyNetworkExecutor, log: SourceLog) -> LCPAdapter {
        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = contentURL
        return LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                log.sources.append(url)
                return nil
            }
        )
    }

    private func makeLoan(since: Date?) -> TPPBook {
        makeBook(
            acquisitionType: lcpLicenseMIME,
            indirect: [indirect(audiobookLCPMIME)],
            availability: TPPOPDSAcquisitionAvailabilityLimited(copiesAvailable: 0, copiesTotal: 1, since: since, until: nil)
        )
    }

    /// Builds an `.lcpa` the way fulfilment does: a whole ZIP into which
    /// `TPPLicensesService.injectLicense` writes the loan's licence.
    private func writePackage(
        embeddingLicenseId id: String,
        issued: String? = nil,
        at url: URL,
        publication: String? = nil
    ) async throws {
        writeWholeArchive(to: url)
        let lcpl = url.deletingLastPathComponent().appendingPathComponent("embedded-\(UUID().uuidString).lcpl")
        try licenseJSON(id: id, issued: issued, publication: publication).write(to: lcpl)
        try await TPPLicensesService().injectLicense(lcpl: lcpl, to: url, at: "license.lcpl")
        try FileManager.default.removeItem(at: lcpl)
    }

    private func resolvedSource(
        for book: TPPBook,
        contentURL: URL,
        network: SpyNetworkExecutor = SpyNetworkExecutor()
    ) async -> URL? {
        let downloadCenter = SpyDownloadCenter()
        downloadCenter.fileUrlByIdentifier[book.identifier] = contentURL
        var captured: URL?
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: network,
            lcpAudiobooksFactory: { url in
                captured = url
                return nil
            }
        )
        _ = await adapter.resolveManifest(for: book)
        return captured
    }

    /// The device state: the `.lcpl` and the package both hold the earlier
    /// loan's licence and the loan's own licence is a different one. The open
    /// must replace the licence and remove the earlier package and its ranges.
    func testResolveManifest_staleLicence_fetchReturnsANewLicence_replacesItAndRemovesThePackageAndStore() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        let publication = uniquePublication()
        let store = try makeArchiveStore(for: publication)
        defer { try? FileManager.default.removeItem(at: store) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try licenseJSON(id: "urn:uuid:earlier-loan", issued: earlierIssued, publication: publication).write(to: licenseURL)
        let network = SpyNetworkExecutor()
        network.stubbedData = licenseJSON(id: "urn:uuid:current-loan", issued: currentIssued)
        network.stubbedResponse = httpResponse(status: 200)

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(network.getCallCount, 1, "the current loan's licence must be fetched")
        XCTAssertEqual(source, licenseURL, "the open must stream on the fetched licence")
        XCTAssertEqual(TPPLCPLicense(url: licenseURL)?.identifier, "urn:uuid:current-loan",
                       "the earlier loan's .lcpl must be replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentURL.path),
                       "the earlier loan's package must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path),
                       "the earlier loan's retained ranges must be removed")
    }

    /// Offline, the loan's licence cannot be fetched. Nothing on disk may be
    /// removed on a guess; the open continues as before.
    func testResolveManifest_staleLicence_fetchFails_keepsThePackageAndOpensIt() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try licenseJSON(id: "urn:uuid:earlier-loan", issued: earlierIssued).write(to: licenseURL)
        let network = SpyNetworkExecutor()
        network.stubbedError = URLError(.notConnectedToInternet)

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(network.getCallCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path), "a failed fetch must not remove the package")
        XCTAssertEqual(TPPLCPLicense(url: licenseURL)?.identifier, "urn:uuid:earlier-loan", "the .lcpl must be kept")
        XCTAssertEqual(source, contentURL, "the open falls through to the package, as before")
    }

    /// The loan's licence is the one already on disk, so the date rule was a
    /// false positive. The package stays, and the confirmation is kept so the
    /// next open does not fetch again.
    func testResolveManifest_staleLicence_fetchReturnsTheSameLicence_keepsThePackageAndDoesNotFetchAgain() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:same-loan", issued: earlierIssued, at: contentURL)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try licenseJSON(id: "urn:uuid:same-loan", issued: earlierIssued).write(to: licenseURL)
        let network = SpyNetworkExecutor()
        network.stubbedData = licenseJSON(id: "urn:uuid:same-loan", issued: earlierIssued)
        network.stubbedResponse = httpResponse(status: 200)
        let log = SourceLog()
        let adapter = makeAdapter(for: book, contentURL: contentURL, network: network, log: log)

        _ = await adapter.resolveManifest(for: book)
        _ = await adapter.resolveManifest(for: book)

        XCTAssertEqual(log.sources, [contentURL, contentURL], "both opens use the package")
        XCTAssertEqual(network.getCallCount, 1, "a confirmed licence must not be fetched on every open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path))
    }

    /// No `.lcpl` on disk and the package's licence is from an earlier loan:
    /// the open fetches the loan's licence and drops the package.
    func testResolveManifest_noLicenceFile_packageLicenceFromAnEarlierLoan_fetchesTheLicence() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        let network = SpyNetworkExecutor()
        network.stubbedData = licenseJSON(id: "urn:uuid:current-loan", issued: currentIssued)
        network.stubbedResponse = httpResponse(status: 200)

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(network.getCallCount, 1)
        XCTAssertEqual(source, licenseURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentURL.path),
                       "a package for another licence must be removed so a current one can be fetched")
    }

    /// No `.lcpl` on disk, and the loan's licence is the one in the package: the
    /// package stays, and the confirmation stops the next open fetching again.
    func testResolveManifest_noLicenceFile_packageHoldsTheLoansLicence_keepsItAndDoesNotFetchAgain() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:same-loan", issued: earlierIssued, at: contentURL)
        let network = SpyNetworkExecutor()
        network.stubbedData = licenseJSON(id: "urn:uuid:same-loan", issued: earlierIssued)
        network.stubbedResponse = httpResponse(status: 200)
        let log = SourceLog()
        let adapter = makeAdapter(for: book, contentURL: contentURL, network: network, log: log)

        _ = await adapter.resolveManifest(for: book)
        _ = await adapter.resolveManifest(for: book)

        XCTAssertEqual(log.sources, [contentURL, contentURL], "both opens use the package")
        XCTAssertEqual(network.getCallCount, 1, "the fetched licence is confirmed, so it is not fetched again")
    }

    /// Offline, with no `.lcpl` and a package from an earlier loan: nothing is
    /// removed, and the open falls back to the package as before.
    func testResolveManifest_noLicenceFile_packageLicenceFromAnEarlierLoan_fetchFails_keepsThePackage() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL)
        let network = SpyNetworkExecutor()
        network.stubbedError = URLError(.notConnectedToInternet)

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(source, contentURL, "a failed fetch falls back to the package")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path))
    }

    /// Without a loan start nothing can be called earlier, so a package whose
    /// licence differs from the `.lcpl` is still kept.
    func testResolveManifest_loanStartUnknown_packageLicenceDiffers_keepsThePackage() async throws {
        let book = makeLoan(since: nil)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL)
        try licenseJSON(id: "urn:uuid:current-loan", issued: currentIssued)
            .write(to: contentURL.deletingPathExtension().appendingPathExtension("lcpl"))

        let source = await resolvedSource(for: book, contentURL: contentURL)

        XCTAssertEqual(source, contentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path), "an unknown loan start must not remove a download")
    }

    /// The `.lcpl` is current but the package holds an earlier loan's licence:
    /// the package and its ranges go, so the background fetch can replace it.
    func testResolveManifest_packageLicenceFromAnEarlierLoan_removesThePackageAndStreams() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        let publication = uniquePublication()
        let store = try makeArchiveStore(for: publication)
        defer { try? FileManager.default.removeItem(at: store) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL,
                               publication: publication)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try licenseJSON(id: "urn:uuid:current-loan", issued: currentIssued).write(to: licenseURL)
        let network = SpyNetworkExecutor()

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(source, licenseURL, "a package holding an earlier loan's licence must not be opened")
        XCTAssertEqual(network.getCallCount, 0, "the current .lcpl needs no fetch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentURL.path), "the stale package must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "its retained ranges must be removed")
    }

    /// Licences issued for the current loan keep the downloaded package.
    func testResolveManifest_licencesIssuedForTheLoan_usesLocalFile() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:current-loan", issued: currentIssued, at: contentURL)
        try licenseJSON(id: "urn:uuid:current-loan", issued: currentIssued)
            .write(to: contentURL.deletingPathExtension().appendingPathExtension("lcpl"))
        let network = SpyNetworkExecutor()

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(source, contentURL, "a package for the current loan is the patron's download")
        XCTAssertEqual(network.getCallCount, 0)
    }

    /// The CM stamps the loan start and the licence server stamps `issued`; a
    /// licence issued seconds before the loan start is still this loan's.
    func testResolveManifest_licenceIssuedWithinTheClockSkew_usesLocalFile() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        // Exactly the 60 s allowance: the edge still counts as this loan.
        let atTheAllowance = "2026-10-30T16:10:18Z"
        try await writePackage(embeddingLicenseId: "urn:uuid:current-loan", issued: atTheAllowance, at: contentURL)
        try licenseJSON(id: "urn:uuid:current-loan", issued: atTheAllowance)
            .write(to: contentURL.deletingPathExtension().appendingPathExtension("lcpl"))
        let network = SpyNetworkExecutor()

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(source, contentURL, "clock skew between the two servers must not discard the download")
        XCTAssertEqual(network.getCallCount, 0)
    }

    /// With no loan start in the feed there is nothing to compare against, so
    /// the earlier behaviour stands.
    func testResolveManifest_loanStartUnknown_usesLocalFile() async throws {
        let book = makeLoan(since: nil)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        try await writePackage(embeddingLicenseId: "urn:uuid:earlier-loan", issued: earlierIssued, at: contentURL)
        try licenseJSON(id: "urn:uuid:earlier-loan", issued: earlierIssued)
            .write(to: contentURL.deletingPathExtension().appendingPathExtension("lcpl"))
        let network = SpyNetworkExecutor()

        let source = await resolvedSource(for: book, contentURL: contentURL, network: network)

        XCTAssertEqual(source, contentURL, "without a loan start the package must not be discarded")
        XCTAssertEqual(network.getCallCount, 0)
    }

    /// A package with no readable licence keeps the earlier behaviour.
    func testResolveManifest_localArchiveWithNoReadableLicense_usesLocalFile() async throws {
        let book = makeLoan(since: loanSince)
        let contentURL = tempBookFileURL(identifier: book.identifier)
        defer { try? FileManager.default.removeItem(at: contentURL.deletingLastPathComponent()) }
        writeWholeArchive(to: contentURL)
        try licenseJSON(id: "urn:uuid:current-loan", issued: currentIssued)
            .write(to: contentURL.deletingPathExtension().appendingPathExtension("lcpl"))

        let source = await resolvedSource(for: book, contentURL: contentURL)

        XCTAssertEqual(source, contentURL, "an unknown embedded licence must not cost the patron their download")
    }

    /// No local `.lcpa`, but a `.lcpl` license sibling file exists. The
    /// adapter must reach for that license file as the LCP source. We force
    /// the factory to nil for the same reason as the previous test.
    func testResolveManifest_licenseFileExists_usesLicenseFile() async {
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

        _ = await adapter.resolveManifest(for: book)

        XCTAssertEqual(capturedFactoryURL, licenseURL,
                       "When only .lcpl exists, that license URL must be the LCP source")
        XCTAssertEqual(network.getCallCount, 0,
                       "Cached license file must skip the network re-download path")
    }

    /// No local `.lcpa`, no `.lcpl` sibling: the adapter must hit the
    /// network to re-download the license. We stub a success response so
    /// the test can also assert the license file lands at the expected
    /// path; the factory still returns nil to keep Readium out of the loop.
    func testResolveManifest_neitherLocalNorLicense_redownloadsLicense() async {
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

        _ = await adapter.resolveManifest(for: book)

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
    func testResolveManifest_redownloadFailure_failsWithLicenseDownloadFailed() async {
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

        var observedError: AudiobookLoadError?
        let result = await adapter.resolveManifest(for: book)
            if case .failure(let err) = result {
                observedError = err
            }

        guard case .licenseDownloadFailed = observedError else {
            XCTFail("Expected .licenseDownloadFailed, got \(String(describing: observedError))")
            return
        }
    }

    /// LCP source resolved (local file exists), but `LCPAudiobooks(for:)`
    /// returns nil — typically because the file isn't a valid LCP package.
    /// The adapter must surface `.lcpInstantiationFailed` distinctly so
    /// the caller can distinguish "no source" from "source unusable".
    func testResolveManifest_lcpInstantiationFailure_failsWithLcpInstantiationFailed() async {
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

        var observedError: AudiobookLoadError?
        let result = await adapter.resolveManifest(for: book)
            if case .failure(let err) = result {
                observedError = err
            }

        guard case .lcpInstantiationFailed = observedError else {
            XCTFail("Expected .lcpInstantiationFailed, got \(String(describing: observedError))")
            return
        }
    }
}

#endif
