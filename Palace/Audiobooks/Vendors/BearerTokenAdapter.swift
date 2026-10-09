//
//  BearerTokenAdapter.swift
//  Palace
//
//  Vendor adapter for the two-step CM fulfill flow: the fulfill URL returns a
//  bearer-token wrapper, and the real manifest is fetched from its location.
//
//  Failure mapping:
//    - network error / empty data / HTML response → .manifestFetchFailed
//    - non-dict JSON                              → .manifestParseFailed
//    - bearer-token shape but second-leg fetch nil → .manifestFetchFailed
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

/// Second-leg bearer-token manifest fetch. Wraps
/// `BookService.fetchManifestWithBearerToken` so adapter tests can stub the
/// recursion without spinning up URLSession or AppContainer.
///
/// `@MainActor` and `async` for the reason recorded on `AudiobookVendorAdapter`
/// (PP-5301).
@MainActor
protocol BearerTokenManifestFetching {
    func fetchManifest(
        with token: MyBooksSimplifiedBearerToken,
        for book: TPPBook
    ) async -> [String: Any]?
}

/// Bearer-token audiobook adapter. Two-step fulfill flow: the CM fulfill
/// endpoint returns a bearer token wrapper (with `access_token` /
/// `location`), and the *real* audiobook manifest lives at the token's
/// `location` URL. This adapter detects the wrapper, mutates the
/// `TPPBook` to record the bearer token + fulfill URL (so the playback
/// pipeline can re-auth on expiration), then fetches the real manifest.
final class BearerTokenAdapter: AudiobookVendorAdapter {

    private let network: AudiobookManifestNetworkFetching
    private let manifestFetcher: BearerTokenManifestFetching

    init(
        network: AudiobookManifestNetworkFetching,
        manifestFetcher: BearerTokenManifestFetching
    ) {
        self.network = network
        self.manifestFetcher = manifestFetcher
    }

    /// The bearer-token shape is only detectable from the fulfill response, so
    /// the loader's dispatch decides whether to use this adapter or
    /// `OpenAccessAdapter`; this adapter accepts any book it is handed.
    func canHandle(_ book: TPPBook) -> Bool {
        return true
    }

    func resolveManifest(
        for book: TPPBook
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        guard let url = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "  ❌ No default acquisition URL for fetching bearer-token wrapper")
            return .failure(.manifestFetchFailed)
        }

        Log.debug(#file, "  📡 Fetching bearer-token wrapper from URL: \(url.absoluteString)")

        let data: Data
        let response: URLResponse?
        do {
            (data, response) = try await network.fetchData(from: url)
        } catch {
            Log.error(#file, "  ❌ Network error fetching bearer-token wrapper: \(error.localizedDescription)")
            return .failure(.manifestFetchFailed)
        }

        guard !data.isEmpty else {
            Log.error(#file, "  ❌ No data received from bearer-token fetch")
            return .failure(.manifestFetchFailed)
        }
        if let httpResponse = response as? HTTPURLResponse,
           AudiobookLoader.looksLikeHTMLResponse(httpResponse) {
            Log.error(#file, "  ⚠️ Server returned HTML instead of bearer-token JSON (HTTP \(httpResponse.statusCode))")
            return .failure(.manifestFetchFailed)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            Log.error(#file, "  ❌ Failed to parse bearer-token data as JSON dictionary")
            return .failure(.manifestParseFailed)
        }

        guard let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json) else {
            Log.error(#file, "  ❌ Response did not contain a recognizable bearer-token wrapper")
            return .failure(.manifestFetchFailed)
        }

        Log.info(#file, "  🔑 Received bearer token from fulfill URL - fetching actual manifest from location")
        bearerToken.fulfillURL = url
        book.bearerToken = bearerToken.accessToken
        book.bearerTokenFulfillURL = url

        guard let manifestJSON = await manifestFetcher.fetchManifest(with: bearerToken, for: book) else {
            Log.error(#file, "  ❌ Bearer-token second-leg manifest fetch returned nil")
            return .failure(.manifestFetchFailed)
        }
        Log.debug(#file, "  ✅ Successfully fetched manifest via bearer token")
        return .success((json: manifestJSON, decryptor: nil))
    }
}
