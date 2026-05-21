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
