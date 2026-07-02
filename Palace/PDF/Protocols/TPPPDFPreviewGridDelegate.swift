//
//  TPPPDFPreviewGridDelegate.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// Delegate protocol for previews and bookmarks.
///
/// `@MainActor`: the sole caller is `TPPPDFPreviewGridController`'s
/// `collectionView(_:didSelectItemAt:)` (a main-actor UIKit delegate callback),
/// and the sole conformer — `TPPPDFPreviewGrid.Coordinator` — forwards into a
/// closure that mutates the main-actor `TPPPDFDocumentMetadata.currentPage`.
/// Pinning the protocol to the main actor makes that isolation explicit and
/// removes the Swift-6 warning without changing behavior.
@MainActor
protocol TPPPDFPreviewGridDelegate {

    /// Is called when a page preiview is tapped.
    /// - Parameter n: Page number.
    func didSelectPage(_ n: Int)
}
