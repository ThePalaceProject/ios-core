//
//  AudiobookVendorAdapter.swift
//  Palace
//
//  Vendor-shape dispatch protocol for AudiobookLoader. Replaces the implicit
//  source-shape branching inside `resolveManifestAndDecryptor` (local file vs
//  bearer-token vs LCP vs open-access network) with an explicit chain of
//  adapters consulted in priority order. First match wins.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

/// A vendor-shape dispatcher that prepares an audiobook manifest (and optional
/// DRM decryptor) for a given `TPPBook`.
///
/// Implementations are consulted by `AudiobookLoader` in priority order: each
/// adapter is asked `canHandle(_:)` and the first to return `true` is the
/// exclusive owner of that load. There is no fall-through — if an adapter
/// returns true it must complete the load (success or failure).
///
/// Conformance contract:
/// - `canHandle(_:)` is synchronous and cheap (property checks, no I/O).
/// - `resolveManifest(for:)` is permitted to perform I/O (disk read, network
///   fetch, license re-download, DRM key refresh).
/// - Errors are mapped to existing `AudiobookLoadError` cases — adapters do
///   not introduce new error types.
///
/// `@MainActor` and `async` rather than a callback (PP-5301). Every adapter
/// previously fetched through a completion handler and hopped the outcome to
/// the main actor itself, because `AudiobookLoader` is `@MainActor` and the
/// closure it passed inherited that isolation while the network layer
/// delivered off it — the PP-5299 crash class. An `await` resumes on the
/// caller's actor, so the hop is not something an adapter has to remember:
/// the mismatch cannot be written here.
@MainActor
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
    /// - Parameter book: The `TPPBook` to load. Distributor, acquisitions, and
    ///   any bearer-token / fulfill URL are accessed from this instance.
    /// - Returns: the parsed manifest dictionary and optional decryptor, or an
    ///   `AudiobookLoadError` describing the failure.
    func resolveManifest(
        for book: TPPBook
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>
}

/// `Sendable` carrier for a parsed `[String: Any]` audiobook manifest.
///
/// `[String: Any]` is not `Sendable` (it holds `Any` existentials that may be
/// reference-typed), and a checked continuation requires a `Sendable` payload.
/// The adapters' own hops are gone now that `resolveManifest` is `async`, so
/// the one remaining crossing is inside the production conformers that bridge
/// a legacy completion-handler API to `async` — `BookService`'s second-leg
/// manifest fetch and `LCPAudiobooks.contentDictionary`.
///
/// - Sendable invariant: `value` is set once at init and only read thereafter.
///   The dictionary is not mutated after boxing, so there is no shared
///   mutation. The `@unchecked` waiver covers only the `Any`-existential
///   payload the compiler cannot prove `Sendable`.
struct ManifestJSONBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) {
        self.value = value
    }
}
