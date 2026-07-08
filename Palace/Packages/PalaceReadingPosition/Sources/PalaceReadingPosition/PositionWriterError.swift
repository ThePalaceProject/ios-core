//
//  PositionWriterError.swift
//  PalaceReadingPosition
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Errors surfaced by `PositionWriter`. The network adapter is the layer
/// that maps `URLSession` / `URLError` cases into these values; the writer
/// re-throws unchanged.
public enum PositionWriterError: Error, Equatable, Sendable {
    /// The snapshot was rejected because the writer is currently throttled.
    /// Callers that want to ensure delivery should retry after the throttle
    /// window elapses, or — preferred — simply call `save(_:)` again with
    /// a fresh snapshot; the writer coalesces.
    case throttled

    /// Network unreachable / DNS failure / offline.
    case networkUnavailable

    /// HTTP 401/403 — the bearer token is missing or rejected.
    case unauthorized

    /// HTTP 4xx/5xx other than 401/403. Body is included verbatim for
    /// logging; do not parse without checking the status code first.
    case serverError(statusCode: Int, body: String?)

    /// The snapshot's `payload` failed to encode/decode against the
    /// server contract.
    case malformedSnapshot

    /// The pending write was explicitly cancelled via `cancel(for:)`.
    case cancelled
}
