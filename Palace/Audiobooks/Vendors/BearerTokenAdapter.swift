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

/// Callback surface for the second-leg bearer-token manifest fetch. Wraps
/// `BookService.fetchManifestWithBearerToken` so adapter tests can stub
/// the recursion without spinning up URLSession or AppContainer.
protocol BearerTokenManifestFetching {
    func fetchManifest(
        with token: MyBooksSimplifiedBearerToken,
        for book: TPPBook,
        completion: @escaping ([String: Any]?) -> Void
    )
}

/// Bearer-token audiobook adapter. Two-step fulfill flow: the CM fulfill
/// endpoint returns a bearer token wrapper (with `access_token` /
/// `location`), and the *real* audiobook manifest lives at the token's
/// `location` URL. This adapter detects the wrapper, mutates the
/// `TPPBook` to record the bearer token + fulfill URL (so the playback
/// pipeline can re-auth on expiration), then fetches the real manifest.
///
/// Not `@MainActor` at the class level because the protocol is not; main-thread
/// hops happen inside callbacks.
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
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        guard let url = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "  ❌ No default acquisition URL for fetching bearer-token wrapper")
            completion(.failure(.manifestFetchFailed))
            return
        }

        Log.debug(#file, "  📡 Fetching bearer-token wrapper from URL: \(url.absoluteString)")

        let completionBox = AudiobookAdapterCompletionBox(completion)
        // The fetcher existential is not `Sendable`; it is only invoked from
        // the main-actor hop below.
        let fetcherBox = BearerManifestFetcherBox(manifestFetcher)
        network.fetchData(from: url) { [fetcherBox] data, response, error in
            Task { @MainActor in
                if let error = error {
                    Log.error(#file, "  ❌ Network error fetching bearer-token wrapper: \(error.localizedDescription)")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }
                guard let data = data, !data.isEmpty else {
                    Log.error(#file, "  ❌ No data received from bearer-token fetch")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   AudiobookLoader.looksLikeHTMLResponse(httpResponse) {
                    Log.error(#file, "  ⚠️ Server returned HTML instead of bearer-token JSON (HTTP \(httpResponse.statusCode))")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }

                guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    Log.error(#file, "  ❌ Failed to parse bearer-token data as JSON dictionary")
                    completionBox.fire(.failure(.manifestParseFailed))
                    return
                }

                guard let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json) else {
                    Log.error(#file, "  ❌ Response did not contain a recognizable bearer-token wrapper")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }

                Log.info(#file, "  🔑 Received bearer token from fulfill URL - fetching actual manifest from location")
                bearerToken.fulfillURL = url
                book.bearerToken = bearerToken.accessToken
                book.bearerTokenFulfillURL = url

                fetcherBox.fetcher.fetchManifest(with: bearerToken, for: book) { manifestJSON in
                    // `[String: Any]` is not Sendable; box it before the hop.
                    guard let manifestJSON = manifestJSON else {
                        Log.error(#file, "  ❌ Bearer-token second-leg manifest fetch returned nil")
                        Task { @MainActor in completionBox.fire(.failure(.manifestFetchFailed)) }
                        return
                    }
                    let jsonBox = ManifestJSONBox(manifestJSON)
                    Task { @MainActor in
                        Log.debug(#file, "  ✅ Successfully fetched manifest via bearer token")
                        completionBox.fire(.success((json: jsonBox.value, decryptor: nil)))
                    }
                }
            }
        }
    }
}
