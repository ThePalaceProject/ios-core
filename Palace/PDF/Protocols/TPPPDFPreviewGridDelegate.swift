//
//  TPPPDFPreviewGridDelegate.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// Delegate protocol for previews and bookmarks.
protocol TPPPDFPreviewGridDelegate {
  
  /// Is called when a page preiview is tapped.
  /// - Parameter n: Page number.
  func didSelectPage(_ n: Int)
}
