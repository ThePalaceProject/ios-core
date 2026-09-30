//
//  CirculationOfflineSupport.swift
//  PalaceNetwork
//
//  Seams for the circulation-analytics offline-retry path, declared here so
//  TPPCirculationAnalytics (in OPDS2) names no app-target Network type, which
//  would create a folder dependency cycle. App-side conformances:
//  NetworkQueue and TPPNetworkExecutor (Palace/Network/).
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
