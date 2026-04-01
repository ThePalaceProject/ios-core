//
//  ShareSheet.swift
//  Palace
//
//  Created for Social Features — UIActivityViewController wrapper.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

/// UIViewControllerRepresentable wrapper for UIActivityViewController.
struct ShareSheet: UIViewControllerRepresentable {

    /// The items to share (text, images, URLs, etc.).
    let items: [Any]

    /// Optional application activities.
    var applicationActivities: [UIActivity]? = nil

    /// Optional excluded activity types.
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    /// Called when the share action completes.
    var onComplete: ((UIActivity.ActivityType?, Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: applicationActivities
        )
        controller.excludedActivityTypes = excludedActivityTypes
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            onComplete?(activityType, completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No dynamic updates needed.
    }
}
