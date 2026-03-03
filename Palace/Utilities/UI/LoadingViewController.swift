//
//  LoadingViewController.swift
//  Palace
//
//  Created by Maurice Carrier on 6/22/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

// accesslint:disable A11Y.UIKIT.VC_TITLE - Title set in loadView; modal overlay, not a navigated screen
class LoadingViewController: UIViewController {
    var spinner = UIActivityIndicatorView(style: .large)

    override func loadView() {
        view = UIView()
        title = NSLocalizedString("Loading", comment: "Loading overlay title")
        view.backgroundColor = UIColor(white: 0, alpha: 0.7)
        view.accessibilityViewIsModal = true
        view.accessibilityLabel = NSLocalizedString("Loading", comment: "Loading overlay accessibility label")

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
    }
}
