//
//  OpenAccessAdapter.swift
//  Palace
//
//  Vendor adapter for the "open-access network fetch" audiobook source shape.
//  Module B of swarm_5c8ddbd5 (Audiobook Vendor Adapter Extraction).
//
//  Carve-out of `AudiobookLoader.fetchOpenAccessManifest` (pre-swarm lines
//  346-396). The recursive bearer-token flow primarily lives in
//  `BearerTokenAdapter` (routed by the top-level-MIME `BearerTokenMIMEGate`),
//  but this fallback adapter also re-detects a bearer-token wrapper at runtime
//  from the fetched body — restoring the pre-swarm body-based detection — so
//  loans whose bearer-token MIME is nested in the indirectAcquisition chain
//  (OverDrive / Unlimited Listens, PP-4631) are still followed to the real
//  manifest when the MIME gate does not claim them.
//
//  Failure mapping (refined from the original code's all-nil completion):
//    - network error    → .manifestFetchFailed
//    - empty/no data    → .manifestFetchFailed
//    - HTML response    → .manifestFetchFailed (server returned a login page)
//    - non-dict JSON    → .manifestParseFailed
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit

/// Minimal callback surface this adapter needs from a network executor.
/// Defined here so adapter tests can inject a stub without dragging the
/// full TPPNetworkExecutor (and its AppContainer.production() coupling)
/// into the test target. Module D wires the production TPPNetworkExecutor
/// adoption when it rewrites loader dispatch.
protocol AudiobookManifestNetworkFetching: AnyObject {
    func fetchData(
        from url: URL,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    )
}

/// Open-access audiobook adapter. Fetches the manifest JSON from
/// `book.defaultAcquisition.hrefURL`. No DRM decryptor is produced.
///
/// Constructor-style DI per CLAUDE.md — the network collaborator is
/// injected so tests can drive both success and failure paths without
/// hitting the network. Production wiring lives in `AudiobookLoader`'s
/// adapter-chain construction (Module D).
///
/// Not `@MainActor`-isolated at the class level — the protocol is not
/// MainActor (see contract notes in `AudiobookVendorAdapter.swift`).
/// The completion-hop to main thread is performed inside the network
/// callback so the protocol's "main-thread completion" guarantee holds.
final class OpenAccessAdapter: AudiobookVendorAdapter {

    private let network: AudiobookManifestNetworkFetching

    /// Optional second-leg fetcher used to recover the pre-swarm runtime
    /// bearer-token flow when a fulfill response turns out to be a
    /// bearer-token wrapper that the top-level-MIME `BearerTokenMIMEGate`
    /// did not catch (PP-4631). Injected in production; `nil` in the
    /// open-access-only adapter tests, which preserves their behavior
    /// (detection is skipped when no fetcher is wired).
    private let bearerTokenManifestFetcher: BearerTokenManifestFetching?

    init(
        network: AudiobookManifestNetworkFetching,
        bearerTokenManifestFetcher: BearerTokenManifestFetching? = nil
    ) {
        self.network = network
        self.bearerTokenManifestFetcher = bearerTokenManifestFetcher
    }

    /// Open-access is the fallback adapter — it accepts any TPPBook the
    /// chain has not yet claimed. The loader's adapter chain places
    /// LCP/LocalFile/BearerToken adapters earlier; OpenAccess is the
    /// last-resort network fetch.
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

        network.fetchData(from: url) { [bearerTokenManifestFetcher] data, response, error in
            Task { @MainActor in
                if let error = error {
                    Log.error(#file, "  ❌ Network error fetching manifest: \(error.localizedDescription)")
                    completion(.failure(.manifestFetchFailed))
                    return
                }
                guard let data = data, !data.isEmpty else {
                    Log.error(#file, "  ❌ No data received from manifest fetch")
                    completion(.failure(.manifestFetchFailed))
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   AudiobookLoader.looksLikeHTMLResponse(httpResponse) {
                    Log.error(#file, "  ⚠️ Server returned HTML instead of JSON - likely a redirect to login or error page (HTTP \(httpResponse.statusCode))")
                    completion(.failure(.manifestFetchFailed))
                    return
                }
                Log.debug(#file, "  ✅ Received \(data.count) bytes of manifest data")

                guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    Log.error(#file, "  ❌ Failed to parse manifest data as JSON dictionary")
                    completion(.failure(.manifestParseFailed))
                    return
                }

                // PP-4631: OverDrive / Unlimited Listens fulfill through a
                // bearer-token wrapper whose MIME is nested in the
                // indirectAcquisition chain, not the top-level
                // `defaultAcquisition.type`. The top-level-only
                // `BearerTokenMIMEGate` therefore misses them and they fall
                // through to this fallback adapter. Restore the pre-swarm
                // runtime (body-based) bearer-token detection so the wrapper
                // is followed to the real manifest instead of being mis-parsed
                // as one (which fails decode → "error opening this book").
                if let bearerTokenManifestFetcher,
                   let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json) {
                    Log.info(#file, "  🔑 Open-access fetch returned a bearer-token wrapper - following second leg to the real manifest")
                    bearerToken.fulfillURL = url
                    book.bearerToken = bearerToken.accessToken
                    book.bearerTokenFulfillURL = url
                    bearerTokenManifestFetcher.fetchManifest(with: bearerToken, for: book) { manifestJSON in
                        Task { @MainActor in
                            guard let manifestJSON = manifestJSON else {
                                Log.error(#file, "  ❌ Bearer-token second-leg manifest fetch returned nil")
                                completion(.failure(.manifestFetchFailed))
                                return
                            }
                            Log.debug(#file, "  ✅ Successfully fetched manifest via bearer token (open-access fallback)")
                            completion(.success((json: manifestJSON, decryptor: nil)))
                        }
                    }
                    return
                }

                Log.debug(#file, "  ✅ Successfully parsed manifest JSON")
                completion(.success((json: json, decryptor: nil)))
            }
        }
    }
}
