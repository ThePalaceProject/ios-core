//
//  TPPOnboardingViewController.swift
//  Palace
//
//  Created by Vladimir Fedorov on 08.12.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

class TPPOnboardingViewController: NSObject {
  @objc static func makeSwiftUIView(dismissHandler: @escaping (() -> Void)) -> UIViewController {
    let controller = UIHostingController(rootView: TPPOnboardingView(dismissHandler: dismissHandler))
    controller.modalPresentationStyle = .fullScreen
    return controller
  }
}
