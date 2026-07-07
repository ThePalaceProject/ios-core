//
//  BearerTokenAdapter.swift
//  Palace
//
//  Vendor adapter for the "open-access fulfill URL returns a bearer-token
//  wrapper, then we fetch the real manifest from the wrapper's location"
//  two-step audiobook source shape (CM fulfill flow).
//
//  Module B of swarm_5c8ddbd5 (Audiobook Vendor Adapter Extraction). Wraps
//  the bearer-token-detection branch and the recursive
//  `BookService.fetchManifestWithBearerToken` call from pre-swarm
//  `AudiobookLoader.swift` lines 346-396 (specifically lines 384-391 are
//  the recursion the adapter codifies; the surrounding fetch+parse mirrors
//  `OpenAccessAdapter` so the adapter is a standalone shape, not a
//  middleware over `OpenAccessAdapter`).
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
/// Constructor-style DI per CLAUDE.md — both the first-leg network and
/// the second-leg manifest fetch are injected so tests cover all paths
/// without hitting URLSession.
///
/// Not `@MainActor`-isolated at the class level — the protocol is not
/// MainActor (see contract notes in `AudiobookVendorAdapter.swift`).
/// Main-thread hops are performed inside callbacks via `Task { @MainActor in }`.
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

    /// Bearer-token shape is detected at runtime from the fulfill response;
    /// the property check alone can't distinguish it from open-access on
    /// the way in. Module D's dispatch decides whether to invoke this
    /// adapter or `OpenAccessAdapter`. Returning `true` here lets the
    /// loader call this adapter directly when it has bearer-token context.
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

        // Box the non-`@Sendable` completion so it can cross the network
        // callback → `Task { @MainActor in }` hops without forcing `@Sendable`
        // onto the `AudiobookVendorAdapter` protocol. See
        // `AudiobookAdapterCompletionBox`.
        let completionBox = AudiobookAdapterCompletionBox(completion)
        // `BearerTokenManifestFetching` is a Palace-local protocol that does NOT
        // refine `Sendable` (refining it would ripple to `BookService` and every
        // adapter test stub). Capturing the bare existential into the
        // `Task { @MainActor in }` hop below trips `sending … risks data races`.
        // Carry it in an `@unchecked Sendable` box whose invariant is that the
        // fetcher is only invoked from the main-actor hop.
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
                    // `[String: Any]?` is not Sendable (it holds `Any`
                    // existentials), so capturing `manifestJSON` into the
                    // `Task { @MainActor in }` hop trips `sending … risks data
                    // races`. Unwrap on the callback's thread and box the
                    // dictionary before the hop; the manifest is produced once
                    // and only read on the main actor thereafter.
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
