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

/// Minimal callback surface this adapter needs from a network executor, so
/// tests can inject a stub instead of `TPPNetworkExecutor`.
protocol AudiobookManifestNetworkFetching: AnyObject {
    func fetchData(
        from url: URL,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    )
}

/// Open-access audiobook adapter. Fetches the manifest JSON from
/// `book.defaultAcquisition.hrefURL`. No DRM decryptor is produced.
///
/// Not `@MainActor` at the class level because the protocol is not; the
/// network callback hops to main so completion fires on main.
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
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        guard let url = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "  ❌ No default acquisition URL for fetching manifest")
            completion(.failure(.manifestFetchFailed))
            return
        }

        Log.debug(#file, "  📡 Fetching manifest from URL: \(url.absoluteString)")

        let completionBox = AudiobookAdapterCompletionBox(completion)
        // The fetcher existential is not `Sendable`; it is only invoked from
        // the main-actor hop below.
        let fetcherBox = bearerTokenManifestFetcher.map(BearerManifestFetcherBox.init)
        network.fetchData(from: url) { [fetcherBox] data, response, error in
            Task { @MainActor in
                if let error = error {
                    Log.error(#file, "  ❌ Network error fetching manifest: \(error.localizedDescription)")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }
                guard let data = data, !data.isEmpty else {
                    Log.error(#file, "  ❌ No data received from manifest fetch")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   AudiobookLoader.looksLikeHTMLResponse(httpResponse) {
                    Log.error(#file, "  ⚠️ Server returned HTML instead of JSON - likely a redirect to login or error page (HTTP \(httpResponse.statusCode))")
                    completionBox.fire(.failure(.manifestFetchFailed))
                    return
                }
                Log.debug(#file, "  ✅ Received \(data.count) bytes of manifest data")

                guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    Log.error(#file, "  ❌ Failed to parse manifest data as JSON dictionary")
                    completionBox.fire(.failure(.manifestParseFailed))
                    return
                }

                // PP-4631: some loans (OverDrive / Unlimited Listens) nest the
                // bearer-token MIME in the indirectAcquisition chain, so
                // `BearerTokenMIMEGate` misses them. Follow the wrapper here
                // rather than decoding it as a manifest.
                if let bearerTokenManifestFetcher = fetcherBox?.fetcher,
                   let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json) {
                    Log.info(#file, "  🔑 Open-access fetch returned a bearer-token wrapper - following second leg to the real manifest")
                    bearerToken.fulfillURL = url
                    book.bearerToken = bearerToken.accessToken
                    book.bearerTokenFulfillURL = url
                    bearerTokenManifestFetcher.fetchManifest(with: bearerToken, for: book) { manifestJSON in
                        // `[String: Any]` is not Sendable; box it before the hop.
                        guard let manifestJSON = manifestJSON else {
                            Log.error(#file, "  ❌ Bearer-token second-leg manifest fetch returned nil")
                            Task { @MainActor in completionBox.fire(.failure(.manifestFetchFailed)) }
                            return
                        }
                        let jsonBox = ManifestJSONBox(manifestJSON)
                        Task { @MainActor in
                            Log.debug(#file, "  ✅ Successfully fetched manifest via bearer token (open-access fallback)")
                            completionBox.fire(.success((json: jsonBox.value, decryptor: nil)))
                        }
                    }
                    return
                }

                Log.debug(#file, "  ✅ Successfully parsed manifest JSON")
                completionBox.fire(.success((json: json, decryptor: nil)))
            }
        }
    }
}
