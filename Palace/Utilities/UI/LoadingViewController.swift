//
//  LoadingViewController.swift
//  Palace
//
//  Created by Maurice Carrier on 6/22/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

class LoadingViewController: UIViewController {
    var spinner = UIActivityIndicatorView(style: .large)

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        title = NSLocalizedString("Loading", comment: "Loading overlay title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = UIView()
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
