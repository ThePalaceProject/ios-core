//
//  Reachability+StreamingReader.swift
//  Palace
//
//  PP-4161: protocol seam that lets `StreamingReaderViewModel` ask "are we
//  online?" without depending on the concrete `PalaceNetwork.Reachability`
//  class. Tests inject a `FakeReachability`; production wires the
//  AppContainer-provided `Reachability` through the conformance below.
//

import Foundation
import PalaceNetwork

/// Minimal connectivity check used by the streaming reader's offline branch.
/// Intentionally small — the reader only needs the synchronous yes/no.
public protocol ReachabilityProviding: AnyObject {
    func isConnectedToNetwork() -> Bool
}

/// `PalaceNetwork.Reachability` already exposes `isConnectedToNetwork()`,
/// so conformance is trivial. Keeps the production wiring concrete (no
/// new singleton) while letting the reader code work against a protocol.
extension Reachability: ReachabilityProviding {}
