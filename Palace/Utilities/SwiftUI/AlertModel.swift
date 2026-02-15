//
//  AlertModel.swift
//  Palace
//
//  Created by Maurice Carrier on 2/17/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

struct AlertModel: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var buttonTitle: String?
    var primaryAction: () -> Void = {}
    var secondaryButtonTitle: String?
    var secondaryAction: () -> Void = {}

    /// Creates a retryable alert with "Retry" and "Cancel" buttons.
    static func retryable(
        title: String,
        message: String,
        retryAction: @escaping () -> Void,
        cancelAction: (() -> Void)? = nil
    ) -> AlertModel {
        AlertModel(
            title: title,
            message: message,
            buttonTitle: Strings.MyDownloadCenter.retry,
            primaryAction: retryAction,
            secondaryButtonTitle: Strings.Generic.cancel,
            secondaryAction: cancelAction ?? {}
        )
    }

    /// Creates an alert shown when the user has exceeded the maximum retry limit.
    static func maxRetriesExceeded(title: String) -> AlertModel {
        AlertModel(
            title: title,
            message: Strings.MyDownloadCenter.tryAgainLater,
            buttonTitle: Strings.Generic.ok
        )
    }
}
