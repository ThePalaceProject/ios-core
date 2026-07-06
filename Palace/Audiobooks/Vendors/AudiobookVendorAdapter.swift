//
//  AudiobookVendorAdapter.swift
//  Palace
//
//  Vendor-shape dispatch protocol for AudiobookLoader. Replaces the implicit
//  source-shape branching inside `resolveManifestAndDecryptor` (local file vs
//  bearer-token vs LCP vs open-access network) with an explicit chain of
//  adapters consulted in priority order. First match wins.
//
//  Module A of swarm_5c8ddbd5 (Audiobook Vendor Adapter Extraction).
//  Downstream modules B (Network adapters), C (LCPAdapter), and D (loader
//  dispatch rewrite) consume this protocol. The shape is intentionally
//  callback-shaped to match the existing loader surface — async/await
//  modernization is reserved for Swarm 3.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import PalaceAudiobookToolkit

/// A vendor-shape dispatcher that prepares an audiobook manifest (and optional
/// DRM decryptor) for a given `TPPBook`.
///
/// Implementations are consulted by `AudiobookLoader` in priority order: each
/// adapter is asked `canHandle(_:)` and the first to return `true` is the
/// exclusive owner of that load. There is no fall-through — if an adapter
/// returns true it MUST complete the load (success or failure).
///
/// Conformance contract:
/// - `canHandle(_:)` is synchronous and cheap (property checks, no I/O).
/// - `resolveManifest(for:completion:)` is permitted to perform I/O
///   (disk read, network fetch, license re-download, DRM key refresh).
/// - `completion` is invoked on the main thread exactly once per call.
/// - Errors are mapped to existing `AudiobookLoadError` cases — adapters do
///   not introduce new error types.
///
/// The protocol is callback-shaped (NOT `async`) because the loader's public
/// surface is callback-shaped and a concurrent rewrite is out of scope for
/// this swarm. Swarm 3 will modernize the loader; until then, conform with
/// `completion(.success(...))` / `completion(.failure(...))`.
protocol AudiobookVendorAdapter {

    /// Returns `true` iff this adapter is responsible for loading `book`.
    ///
    /// Called once per book per load attempt, in adapter-chain order. Must be
    /// synchronous and inexpensive — no network, no disk I/O beyond cheap
    /// `FileManager.fileExists` checks. Returning `true` commits this adapter
    /// to driving the load to completion; the chain stops here.
    func canHandle(_ book: TPPBook) -> Bool

    /// Produce the audiobook manifest JSON and an optional `DRMDecryptor` for
    /// `book`. Called only when this adapter previously returned `true` from
    /// `canHandle(_:)`.
    ///
    /// - Parameters:
    ///   - book: The `TPPBook` to load. Distributor, acquisitions, and any
    ///     bearer-token / fulfill URL are accessed from this instance.
    ///   - completion: Invoked exactly once on the main thread with either
    ///     the parsed manifest dictionary + optional decryptor, or an
    ///     `AudiobookLoadError` describing the failure.
    func resolveManifest(
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    )
}

/// `Sendable` carrier for an `AudiobookVendorAdapter` completion.
///
/// The `resolveManifest` completion is intentionally NOT `@Sendable` — the
/// protocol is consumed by `AudiobookLoader` (and its test doubles) whose call
/// sites pass plain callbacks; marking the protocol `@Sendable` would ripple
/// through the loader's completion chain and every adapter test mock. But each
/// adapter must hand the completion across a `Task { @MainActor in }` /
/// `DispatchQueue.main.async` hop to satisfy the "completion fires on main"
/// contract. Wrapping it in this box lets it cross that `@Sendable` boundary
/// without the protocol change. Mirrors `SendableDecryptCompletion`
/// (LCPAudiobooks) and `TokenReadyCompletionBox` (AudiobookLoader).
///
/// - Sendable invariant: `fire(_:)` forwards to the wrapped closure exactly
///   once per adapter load (the adapters return after each `completion` call),
///   from a single main-hop continuation — never concurrently. The wrapped
///   closure is otherwise opaque, hence `@unchecked`.
struct AudiobookAdapterCompletionBox: @unchecked Sendable {
    typealias Outcome = Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>
    private let completion: (Outcome) -> Void

    init(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion
    }

    func fire(_ outcome: Outcome) {
        completion(outcome)
    }
}

/// `Sendable` carrier for a parsed `[String: Any]` audiobook manifest.
///
/// `[String: Any]` is not `Sendable` (it holds `Any` existentials that may be
/// reference-typed), so it cannot cross a `Task { @MainActor in }` boundary
/// directly. `LocalFileAdapter` parses the manifest BEFORE its bearer-token
/// refresh hop and must carry it across into the main-actor completion; this
/// box makes that crossing explicit.
///
/// - Sendable invariant: `value` is set once at init and only read thereafter
///   — the dictionary is not mutated after boxing, so there is no shared
///   mutation. The `@unchecked` waiver covers only the `Any`-existential
///   payload the compiler cannot prove `Sendable`. Adapters that build the
///   dictionary INSIDE the hop (OpenAccess / BearerToken) don't need this box.
struct ManifestJSONBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) {
        self.value = value
    }
}
