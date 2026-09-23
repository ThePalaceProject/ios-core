//
//  CirculationOfflineSupport.swift
//  PalaceNetwork
//
//  Wave 1c (god-class decomposition, cycle 3): seam protocols for the
//  circulation-analytics offline-retry path. Declared package-side so the
//  relocated TPPCirculationAnalytics names NO app-target Network type
//  (naming NetworkQueue/TPPNetworkExecutor from its new OPDS2 home would
//  re-mint the folder cycle this wave dissolves). App-side conformances:
//  NetworkQueue + TPPNetworkExecutor (Palace/Network/).
//

import Foundation

/// Enqueues a request into the offline retry queue.
public protocol OfflineRequestEnqueuing: Sendable {
    func enqueueOfflineRequest(
        libraryID: String,
        updateID: String?,
        url: URL,
        method: HTTPMethod,
        parameters: Data?,
        headers: [String: String]?
    )
}

/// Builds an authorized URLRequest (auth headers applied) for a URL.
public protocol AuthorizedRequestProviding: Sendable {
    func authorizedRequest(for url: URL) -> URLRequest
}
