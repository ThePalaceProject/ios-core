//
//  StreamingReaderViewModel.swift
//  Palace
//
//  PP-4161: state machine + progress-store coordinator for the WKWebView
//  streaming reader. Owns the URL the web view should load, tracks the
//  latest scroll offset reported by the view controller, and persists the
//  offset on dismiss so reopens land at the saved position.
//
//  Online-only: if reachability says offline at init (or after `reload()`),
//  the VM emits `.offline` and never loads the URL — see anti-claims in
//  `.forgeos/intent/pp-4161-streaming-html-reader.md`.
//

import Combine
import CoreGraphics
import Foundation
import PalaceNetwork

/// State surface bound to `StreamingReaderViewController`.
/// - `loading`: transient state before reachability evaluation completes.
/// - `ready(URL, restoredScroll:)`: web view should load `URL`; if
///   `restoredScroll` is non-nil, scroll there after navigation finishes.
/// - `offline`: render the "Connection required" view with a Retry button.
/// - `failed`: render an error view (e.g. WKNavigationDelegate reported a
///   non-recoverable navigation failure).
public enum StreamingReaderState {
    case loading
    case ready(URL, restoredScroll: CGFloat?)
    case offline
    case failed(Error)
}

@MainActor
public final class StreamingReaderViewModel: ObservableObject {

    // MARK: - Public surface

    @Published public private(set) var state: StreamingReaderState = .loading

    public let book: TPPBook

    // MARK: - Dependencies

    private let store: StreamingReaderProgressStoring
    private let reachability: ReachabilityProviding
    private let urlSession: URLSession

    // MARK: - State

    /// The most recent scroll offset reported by the view controller. `nil`
    /// until the web view has fired at least one navigation/scroll event,
    /// so we don't persist a spurious 0 if the user dismisses immediately.
    private var latestScrollOffset: CGFloat?

    // MARK: - Init

    public init(
        book: TPPBook,
        store: StreamingReaderProgressStoring,
        reachability: ReachabilityProviding,
        urlSession: URLSession = .shared
    ) {
        self.book = book
        self.store = store
        self.reachability = reachability
        self.urlSession = urlSession
        self.state = computeInitialState()
    }

    // MARK: - View-controller-facing API

    /// Called by the view controller when a WKWebView scroll event lands
    /// (or when `didFinish navigation` reports a new content offset).
    public func didNavigationFinish(scrollOffset: CGFloat) {
        latestScrollOffset = scrollOffset
    }

    /// Called by the view controller in `viewDidDisappear` (or by the
    /// SwiftUI wrapper's onDisappear). Persists the latest scroll offset
    /// synchronously so a fast reopen lands at the saved position.
    public func didDismiss() {
        guard let offset = latestScrollOffset else { return }
        store.save(scrollOffset: offset, fragment: nil, forBookID: book.identifier)
    }

    /// Retry button on the offline state re-evaluates reachability and
    /// transitions to `.ready` if the network is back.
    public func reload() {
        state = computeInitialState()
    }

    // MARK: - Helpers

    private func computeInitialState() -> StreamingReaderState {
        guard reachability.isConnectedToNetwork() else {
            return .offline
        }
        guard let url = streamingURL() else {
            // No openable acquisition leaf — treat as offline rather than
            // crashing or rendering an empty web view.
            return .offline
        }
        let restored = store.read(forBookID: book.identifier)
        return .ready(url, restoredScroll: restored?.scrollOffset)
    }

    private func streamingURL() -> URL? {
        book.defaultAcquisition?.hrefURL
    }
}
