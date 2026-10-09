//
//  Adapters+Production.swift
//  Palace
//
//  Production conformances for the vendor adapters' collaborator protocols
//  (AudiobookManifestNetworkFetching, BearerTokenManifestFetching,
//  AudiobookFileReading, BearerTokenRefreshing) plus the BearerTokenMIMEGate
//  that controls when BearerTokenAdapter claims a book. Each is a thin
//  delegating wrapper; behavior is tested through the adapters.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

/// Production conformance for `AudiobookManifestNetworkFetching`. Delegates
/// to `TPPNetworkExecutor.GET` with the executor's cache + token defaults.
/// Used by both OpenAccessAdapter (single-leg) and BearerTokenAdapter
/// (first-leg of the two-step wrapper flow).
final class ProductionAudiobookManifestFetcher: AudiobookManifestNetworkFetching {
    private let executor: TPPNetworkExecutor

    init(executor: TPPNetworkExecutor) {
        self.executor = executor
    }

    func fetchData(from url: URL) async throws -> (Data, URLResponse?) {
        // `request(for:)`, not a bare `URLRequest(url:)`. It is what stamps the
        // `Authorization: Bearer` header, the custom User-Agent, the SAML
        // cookies, `Accept-Language` and the HTTP/3 opt-out; the request-taking
        // overload dispatches what it is handed, and `useTokenIfAvailable` only
        // controls the proactive refresh rather than adding the header.
        //
        // What a bare request costs, stated precisely because an earlier
        // version of this comment said "terminal 401" and that is wrong for the
        // common case: the 401 repair is gated on `snapshot.hasCredentials`
        // (`TPPNetworkResponder.swift:615`), not on having sent a header, and
        // the retry is rebuilt through `request(for:)`
        // (`TPPNetworkExecutor.swift:1001`). So for token and OAuth libraries
        // the fetch still succeeds — after a wasted round trip, a spurious
        // token exchange, the per-URL retry budget (`maxRetryAttempts = 1`) and
        // `markCredentialsStale()`, which can surface as an unprompted
        // re-login. It is terminal only where the repair declines: basic auth,
        // and browser reauth (`TPPNetworkResponder.swift:659`).
        try await executor.GET(request: executor.request(for: url),
                               cachePolicy: .useProtocolCachePolicy,
                               useTokenIfAvailable: true)
    }
}

/// Production conformance for `AudiobookFileReading`. Thin wrapper over
/// `FileManager.default` + `Data(contentsOf:)` so the disk-read path stays
/// substitutable in tests.
final class ProductionAudiobookFileReader: AudiobookFileReading {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// Production conformance for `BearerTokenRefreshing`. Wraps the static
/// `MyBooksSimplifiedBearerToken.refreshToken(from:completion:)` so the
/// refresh seam is substitutable from the LocalFileAdapter test surface.
final class ProductionBearerTokenRefresher: BearerTokenRefreshing {
    func refreshToken(from fulfillURL: URL) async -> MyBooksSimplifiedBearerToken? {
        await withCheckedContinuation { continuation in
            MyBooksSimplifiedBearerToken.refreshToken(from: fulfillURL) { token in
                continuation.resume(returning: token)
            }
        }
    }
}

/// Production conformance for `BearerTokenManifestFetching`. Wraps the
/// static `BookService.fetchManifestWithBearerToken` second-leg call so
/// BearerTokenAdapter tests can stub the recursion without spinning up
/// URLSession.
final class ProductionBearerTokenManifestFetcher: BearerTokenManifestFetching {
    func fetchManifest(
        with token: MyBooksSimplifiedBearerToken,
        for book: TPPBook
    ) async -> [String: Any]? {
        // `[String: Any]` is not `Sendable`, so the continuation carries it in
        // `ManifestJSONBox`; the resumption lands back on this actor.
        let boxed: ManifestJSONBox? = await withCheckedContinuation { continuation in
            BookService.fetchManifestWithBearerToken(token, for: book) { json in
                continuation.resume(returning: json.map(ManifestJSONBox.init))
            }
        }
        return boxed?.value
    }
}

/// MIME-gated wrapper around BearerTokenAdapter so it only claims books
/// whose `defaultAcquisition.type` advertises the bearer-token wrapper
/// MIME. The underlying adapter's `canHandle` returns true unconditionally;
/// this gate keeps OpenAccessAdapter as the fallback for non-bearer-token
/// books.
final class BearerTokenMIMEGate: AudiobookVendorAdapter {
    static let bearerTokenMIME = "application/vnd.librarysimplified.bearer-token+json"

    private let wrapped: AudiobookVendorAdapter

    init(wrapped: AudiobookVendorAdapter) {
        self.wrapped = wrapped
    }

    func canHandle(_ book: TPPBook) -> Bool {
        guard let type = book.defaultAcquisition?.type else { return false }
        return type == Self.bearerTokenMIME
    }

    func resolveManifest(
        for book: TPPBook
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        await wrapped.resolveManifest(for: book)
    }
}
