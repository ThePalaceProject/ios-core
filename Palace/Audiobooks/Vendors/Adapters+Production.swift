//
//  Adapters+Production.swift
//  Palace
//
//  Production conformances for Module B's adapter-local collaborator
//  protocols (AudiobookManifestNetworkFetching, BearerTokenManifestFetching,
//  AudiobookFileReading, BearerTokenRefreshing) plus the BearerTokenMIMEGate
//  wrapper that controls when BearerTokenAdapter claims a book in the chain.
//
//  Module D of swarm_5c8ddbd5 (Audiobook Vendor Adapter Extraction).
//
//  The adapter classes themselves live in Module B and are test-injected with
//  these collaborators stubbed. The loader's `makeProductionAdapters()`
//  assembles the chain pulling these production conformances and the LCP
//  adapter (Module C). Each conformance is a thin wrapper — no logic beyond
//  delegation — so the adapter test suites (Module B) remain the behavior
//  authority and these wrappers only need a smoke test through the build.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import PalaceAudiobookToolkit

/// Production conformance for `AudiobookManifestNetworkFetching`. Delegates
/// to `TPPNetworkExecutor.GET` with the executor's cache + token defaults.
/// Used by both OpenAccessAdapter (single-leg) and BearerTokenAdapter
/// (first-leg of the two-step wrapper flow).
final class ProductionAudiobookManifestFetcher: AudiobookManifestNetworkFetching {
    private let executor: TPPNetworkExecutor

    init(executor: TPPNetworkExecutor) {
        self.executor = executor
    }

    func fetchData(
        from url: URL,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        _ = executor.GET(url, cachePolicy: .useProtocolCachePolicy, useTokenIfAvailable: true) { data, response, error in
            completion(data, response, error)
        }
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
    func refreshToken(
        from fulfillURL: URL,
        completion: @escaping @Sendable (MyBooksSimplifiedBearerToken?) -> Void
    ) {
        MyBooksSimplifiedBearerToken.refreshToken(from: fulfillURL, completion: completion)
    }
}

/// Production conformance for `BearerTokenManifestFetching`. Wraps the
/// static `BookService.fetchManifestWithBearerToken` second-leg call so
/// BearerTokenAdapter tests can stub the recursion without spinning up
/// URLSession.
final class ProductionBearerTokenManifestFetcher: BearerTokenManifestFetching {
    func fetchManifest(
        with token: MyBooksSimplifiedBearerToken,
        for book: TPPBook,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        BookService.fetchManifestWithBearerToken(token, for: book, completion: completion)
    }
}

/// MIME-gated wrapper around BearerTokenAdapter so it only claims books
/// whose `defaultAcquisition.type` advertises the bearer-token wrapper
/// MIME. The underlying adapter's `canHandle` returns true unconditionally
/// (Module B contract decision) — this wrapper is Module D's per-book
/// gate that keeps OpenAccessAdapter as the chain's fallback for
/// non-bearer-token books.
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
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        wrapped.resolveManifest(for: book, completion: completion)
    }
}
