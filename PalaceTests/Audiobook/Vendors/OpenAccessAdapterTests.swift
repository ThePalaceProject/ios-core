//
//  OpenAccessAdapterTests.swift
//  PalaceTests
//
//  Mutation-killing tests for `OpenAccessAdapter` — the open-access
//  network-fetch carve-out from pre-swarm `AudiobookLoader.swift` lines
//  346-396 (minus the bearer-token branch, which lives in
//  `BearerTokenAdapter`).
//
//  Every test drives a single decision point through both branches so the
//  mutation engine cannot flip a conditional without killing at least one
//  test. The network collaborator is a constructor-injected stub — zero
//  real network, zero AppContainer.production() reads.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class OpenAccessAdapterTests: XCTestCase {

    // MARK: - Stub network

    private final class StubNetwork: AudiobookManifestNetworkFetching {
        var stubbedData: Data?
        var stubbedResponse: URLResponse?
        var stubbedError: Error?
        private(set) var requestedURLs: [URL] = []

        func fetchData(
            from url: URL,
            completion: @escaping (Data?, URLResponse?, Error?) -> Void
        ) {
            requestedURLs.append(url)
            // Hop off the call stack to mirror real URLSession ordering.
            DispatchQueue.main.async { [stubbedData, stubbedResponse, stubbedError] in
                completion(stubbedData, stubbedResponse, stubbedError)
            }
        }
    }

    private func makeResponse(url: URL, status: Int, contentType: String? = nil) -> HTTPURLResponse {
        let headers = contentType.map { ["Content-Type": $0] }
        return HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func makeBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    }

    // MARK: - canHandle

    /// OpenAccess is the fallback adapter — it MUST accept any book the
    /// chain hands it. Mutation point: flipping `return true` to `return
    /// false` would break the loader's fallback path. This test fails the
    /// mutant by asserting true on a non-LCP, non-local OPDS book.
    func testCanHandle_anyOPDSBook_returnsTrueAsFallback() {
        let network = StubNetwork()
        let adapter = OpenAccessAdapter(network: network)
        let book = makeBook()

        XCTAssertTrue(
            adapter.canHandle(book),
            "OpenAccess is the chain's fallback — it must always accept"
        )
    }

    // MARK: - resolveManifest success

    func testResolveManifest_successPath_completesWithJSON() {
        let network = StubNetwork()
        let json: [String: Any] = ["@type": "Audiobook", "title": "Test"]
        network.stubbedData = try! JSONSerialization.data(withJSONObject: json, options: [])
        let book = makeBook()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )

        let adapter = OpenAccessAdapter(network: network)
        let exp = expectation(description: "resolveManifest success")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(observed?.json["title"] as? String, "Test",
                       "Parsed JSON must propagate through to caller verbatim")
        XCTAssertEqual(observed?.json["@type"] as? String, "Audiobook")
        XCTAssertNil(observed?.decryptor,
                     "Open-access produces no DRM decryptor — must be nil")
        XCTAssertEqual(network.requestedURLs.count, 1,
                       "Adapter performed exactly one network fetch")
    }

    // MARK: - resolveManifest failure paths

    func testResolveManifest_networkError_failsWithManifestFetchFailed() {
        let network = StubNetwork()
        network.stubbedError = NSError(domain: "test.network", code: -1, userInfo: nil)
        let adapter = OpenAccessAdapter(network: network)
        let book = makeBook()

        let exp = expectation(description: "resolveManifest network error")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("Network error must map to .manifestFetchFailed, got \(String(describing: observed))")
            return
        }
    }

    func testResolveManifest_emptyData_failsWithManifestFetchFailed() {
        let network = StubNetwork()
        network.stubbedData = Data()
        let book = makeBook()
        network.stubbedResponse = makeResponse(url: book.defaultAcquisition!.hrefURL, status: 200)
        let adapter = OpenAccessAdapter(network: network)

        let exp = expectation(description: "resolveManifest empty data")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("Empty data must map to .manifestFetchFailed, got \(String(describing: observed))")
            return
        }
    }

    func testResolveManifest_htmlResponse_failsWithManifestFetchFailed() {
        // A login-redirect page is HTML with a 200 status code and a body.
        // The HTML check must short-circuit BEFORE JSON parsing (which
        // would map to .manifestParseFailed). This pins the failure-mode
        // distinction the contract specifies.
        let network = StubNetwork()
        let htmlBody = "<html><body>Please log in</body></html>".data(using: .utf8)!
        network.stubbedData = htmlBody
        let book = makeBook()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "text/html; charset=utf-8"
        )
        let adapter = OpenAccessAdapter(network: network)

        let exp = expectation(description: "resolveManifest html response")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("HTML response must map to .manifestFetchFailed (not parseFailed), got \(String(describing: observed))")
            return
        }
    }

    func testResolveManifest_invalidJSON_failsWithManifestParseFailed() {
        // Non-HTML, non-empty, non-dict bytes — the actual "we got data
        // but it's not a JSON dict" branch. Drives the
        // `.manifestParseFailed` mapping that distinguishes parse from
        // fetch failures in the error surface.
        let network = StubNetwork()
        network.stubbedData = "[1,2,3]".data(using: .utf8)!  // valid JSON, but an array
        let book = makeBook()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )
        let adapter = OpenAccessAdapter(network: network)

        let exp = expectation(description: "resolveManifest invalid JSON")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestParseFailed = observed else {
            XCTFail("Non-dict JSON must map to .manifestParseFailed, got \(String(describing: observed))")
            return
        }
    }
}
