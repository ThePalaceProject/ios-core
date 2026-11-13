//
//  OpenAccessAdapter.swift
//
//  Vendor adapter for the open-access network fetch (the fallback). It also
//  follows a bearer-token wrapper in the fetched body, for loans whose
//  bearer-token MIME is nested in the indirectAcquisition chain (PP-4631).
//
//  Failures: network error, empty data, or HTML (a login page) map to
//  .manifestFetchFailed; non-dictionary JSON maps to .manifestParseFailed.
//

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

/// Minimal network surface this adapter needs, so tests can inject a stub
/// instead of `TPPNetworkExecutor`.
///
/// `@MainActor` and `async` for the reason recorded on `AudiobookVendorAdapter`:
/// a completion handler here could not say which executor it ran on, and the
/// adapters that consumed it are main-actor types (PP-5301).
@MainActor
protocol AudiobookManifestNetworkFetching: AnyObject {
    /// The response body and its `URLResponse`. Throws the transport error
    /// rather than returning it beside the data.
    func fetchData(from url: URL) async throws -> (Data, URLResponse?)
}

/// Open-access audiobook adapter. Fetches the manifest JSON from
/// `book.defaultAcquisition.hrefURL`. No DRM decryptor is produced.
final class OpenAccessAdapter: AudiobookVendorAdapter {

    private let network: AudiobookManifestNetworkFetching

    /// Second-leg fetcher for a bearer-token wrapper that `BearerTokenMIMEGate`
    /// did not catch (PP-4631). When `nil`, wrapper detection is skipped.
    private let bearerTokenManifestFetcher: BearerTokenManifestFetching?

    init(
        network: AudiobookManifestNetworkFetching,
        bearerTokenManifestFetcher: BearerTokenManifestFetching? = nil
    ) {
        self.network = network
        self.bearerTokenManifestFetcher = bearerTokenManifestFetcher
    }

    /// Fallback adapter: accepts any book the earlier adapters did not claim.
    func canHandle(_ book: TPPBook) -> Bool {
        return true
    }

    func resolveManifest(
        for book: TPPBook
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        guard let url = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "  ❌ No default acquisition URL for fetching manifest")
            return .failure(.manifestFetchFailed)
        }

        Log.debug(#file, "  📡 Fetching manifest from URL: \(url.absoluteString)")

        let data: Data
        let response: URLResponse?
        do {
            (data, response) = try await network.fetchData(from: url)
        } catch {
            Log.error(#file, "  ❌ Network error fetching manifest: \(error.localizedDescription)")
            return .failure(.manifestFetchFailed)
        }

        guard !data.isEmpty else {
            Log.error(#file, "  ❌ No data received from manifest fetch")
            return .failure(.manifestFetchFailed)
        }
        if let httpResponse = response as? HTTPURLResponse,
           AudiobookLoader.looksLikeHTMLResponse(httpResponse) {
            Log.error(#file, "  ⚠️ Server returned HTML instead of JSON - likely a redirect to login or error page (HTTP \(httpResponse.statusCode))")
            return .failure(.manifestFetchFailed)
        }
        Log.debug(#file, "  ✅ Received \(data.count) bytes of manifest data")

        guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            Log.error(#file, "  ❌ Failed to parse manifest data as JSON dictionary")
            return .failure(.manifestParseFailed)
        }

        // PP-4631: some loans (OverDrive / Unlimited Listens) nest the
        // bearer-token MIME in the indirectAcquisition chain, so
        // `BearerTokenMIMEGate` misses them. Follow the wrapper here rather
        // than decoding it as a manifest.
        if let bearerTokenManifestFetcher,
           let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json) {
            Log.info(#file, "  🔑 Open-access fetch returned a bearer-token wrapper - following second leg to the real manifest")
            bearerToken.fulfillURL = url
            book.bearerToken = bearerToken.accessToken
            book.bearerTokenFulfillURL = url

            guard let manifestJSON = await bearerTokenManifestFetcher.fetchManifest(with: bearerToken, for: book) else {
                Log.error(#file, "  ❌ Bearer-token second-leg manifest fetch returned nil")
                return .failure(.manifestFetchFailed)
            }
            Log.debug(#file, "  ✅ Successfully fetched manifest via bearer token (open-access fallback)")
            return .success((json: manifestJSON, decryptor: nil))
        }

        Log.debug(#file, "  ✅ Successfully parsed manifest JSON")
        return .success((json: json, decryptor: nil))
    }
}
