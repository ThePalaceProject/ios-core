//
//  StreamingReaderView.swift
//  Palace
//
//  PP-4161: SwiftUI surface for the streaming reader. Wraps
//  `StreamingReaderViewController` via `UIViewControllerRepresentable` so it
//  matches the Reader2 / Reader3 presentation pattern from BookDetail.
//

import SwiftUI
import UIKit
import PalaceNetwork

/// SwiftUI wrapper around `StreamingReaderViewController`. The book and
/// store are captured at init; the wrapper presents the VC inside a
/// `UINavigationController` so the Close bar-button-item has a navigation
/// bar to live in.
public struct StreamingReaderView: UIViewControllerRepresentable {

    private let book: TPPBook
    private let store: StreamingReaderProgressStoring
    private let reachability: ReachabilityProviding

    public init(
        book: TPPBook,
        store: StreamingReaderProgressStoring = StreamingReaderProgressStore(),
        reachability: ReachabilityProviding = Reachability()
    ) {
        self.book = book
        self.store = store
        self.reachability = reachability
    }

    public func makeUIViewController(context: Context) -> UINavigationController {
        let viewModel = StreamingReaderViewModel(
            book: book,
            store: store,
            reachability: reachability
        )
        let reader = StreamingReaderViewController(viewModel: viewModel)
        return UINavigationController(rootViewController: reader)
    }

    public func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // No-op — the reader's state is owned by its view model.
    }
}
